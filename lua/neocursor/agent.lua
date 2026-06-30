-- neocursor: runs cursor-agent headless and parses its stream-json (NDJSON) output.
local config = require("neocursor.config")

local M = {}

-- Build the argv used to invoke cursor-agent for a single request.
-- req: { prompt, mode, session_id }
local function build_cmd(req)
  local o = config.options
  local cmd = {
    o.cmd,
    "-p",
    "--output-format", "stream-json",
    "--stream-partial-output",
  }

  if o.trust then
    table.insert(cmd, "--trust")
  end

  local mode = req.mode or o.default_mode
  if mode == "ask" then
    vim.list_extend(cmd, { "--mode", "ask" })
  elseif mode == "plan" then
    vim.list_extend(cmd, { "--mode", "plan" })
  elseif mode == "agent" then
    if o.agent_force then
      table.insert(cmd, "--force")
    end
  end

  if o.model and o.model ~= "" then
    vim.list_extend(cmd, { "--model", o.model })
  end

  -- Resume keeps the same conversation/session for follow-up turns.
  if req.session_id and req.session_id ~= "" then
    vim.list_extend(cmd, { "--resume", req.session_id })
  end

  -- Prompt is positional and passed as a single argv element (no shell), so
  -- newlines and special characters are safe.
  table.insert(cmd, req.prompt)
  return cmd
end

-- run a request.
-- req fields:
--   prompt      (string)   final prompt text
--   mode        (string)   "ask" | "agent" | "plan"
--   session_id  (string?)  resume an existing session
--   cwd         (string?)  working directory for the agent
--   on_event    (fn(obj))  called per decoded JSON event (on main loop)
--   on_done     (fn(code, stderr)) called when the process exits (on main loop)
-- returns the job id (number) or nil on failure.
function M.run(req)
  local cmd = build_cmd(req)
  local pending = ""
  local stderr_acc = {}

  local function emit(line)
    if line == nil or line == "" then
      return
    end
    local ok, obj = pcall(vim.json.decode, line)
    if ok and type(obj) == "table" then
      req.on_event(obj)
    end
  end

  local job = vim.fn.jobstart(cmd, {
    cwd = req.cwd,
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then
        return
      end
      -- jobstart splits on \n; rejoining with \n reproduces the raw bytes for
      -- this callback. We accumulate and split on real newlines ourselves so
      -- partial JSON lines across callbacks are handled correctly.
      pending = pending .. table.concat(data, "\n")
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        local line = pending:sub(1, nl - 1)
        pending = pending:sub(nl + 1)
        vim.schedule(function()
          emit(line)
        end)
      end
    end,
    on_stderr = function(_, data)
      if not data then
        return
      end
      for _, chunk in ipairs(data) do
        if chunk ~= "" then
          table.insert(stderr_acc, chunk)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        -- Flush any trailing line without a newline.
        if pending ~= "" then
          local leftover = pending
          pending = ""
          emit(leftover)
        end
        if req.on_done then
          req.on_done(code, table.concat(stderr_acc, "\n"))
        end
      end)
    end,
  })

  if job <= 0 then
    if req.on_done then
      req.on_done(-1, "failed to start '" .. tostring(config.options.cmd) .. "' (is cursor-agent installed and on PATH?)")
    end
    return nil
  end

  return job
end

-- Stop an in-flight job.
function M.stop(job)
  if job and job > 0 then
    pcall(vim.fn.jobstop, job)
  end
end

-- List available models via `cursor-agent --list-models`.
-- cb(models, code) where models = { { id, label, current, default }, ... }.
-- Always includes an "auto" entry first.
function M.list_models(cb)
  local out = {}
  local job = vim.fn.jobstart({ config.options.cmd, "--list-models" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(out, data)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local models = {}
        local seen = {}
        for _, line in ipairs(out) do
          local id, label = line:match("^(%S+)%s+%-%s+(.+)$")
          if id and not seen[id] then
            seen[id] = true
            local current = label:match("%(current%)") ~= nil
            local default = label:match("%(default%)") ~= nil
            label = label:gsub("%s*%(current%)%s*$", ""):gsub("%s*%(default%)%s*$", "")
            table.insert(models, { id = id, label = label, current = current, default = default })
          end
        end
        cb(models, code)
      end)
    end,
  })

  if job <= 0 then
    cb({}, -1)
  end
end

return M
