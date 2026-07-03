-- neocursor: the sidebar chat UI (conversation + prompt windows) and streaming
-- render of cursor-agent responses.
--
-- Multiple panels can be open at once, each with its own session, mode, model
-- and in-flight job, so several conversations can run in parallel. Panels
-- stack vertically inside the sidebar column. Commands act on the "current"
-- panel: the one your cursor is in, else the most recently used one.
local config = require("neocursor.config")
local agent = require("neocursor.agent")
local context = require("neocursor.context")
local diff = require("neocursor.diff")
local sessions = require("neocursor.sessions")

local M = {}

local uv = vim.uv or vim.loop

----------------------------------------------------------------------
-- panel registry
----------------------------------------------------------------------

local panels = {}       -- list of panel state tables, in creation order
local last_panel = nil  -- most recently focused/used panel
local _panel_seq = 0

local function buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function panel_alive(p)
  return p and buf_valid(p.conv_buf) and buf_valid(p.prompt_buf)
end

local function panel_open(p)
  return p ~= nil and win_valid(p.conv_win) and win_valid(p.prompt_win)
end

local function new_panel_state()
  _panel_seq = _panel_seq + 1
  return {
    id = _panel_seq,
    conv_buf = nil,
    conv_win = nil,
    prompt_buf = nil,
    prompt_win = nil,
    session_id = nil,
    title = nil,           -- short session title (from the first prompt)
    mode = nil,
    model = nil,           -- selected model id for this panel (nil => auto)
    job = nil,
    busy = false,
    got_result = false,
    rendered_any = false,  -- did this turn render any text/tool output?
    stream_text = "",
    assistant_start = 0,   -- 0-based line where the streaming answer begins
    pending_selection = nil,
    changes = {},          -- file changes made by the agent this session
    turns = 0,
    cwd = nil,             -- cwd of the last submitted turn
    spinner = { timer = nil, idx = 1 },
    closing = false,       -- guard for the WinClosed sibling-close autocmd
    augroup = nil,
  }
end

-- Drop panels whose buffers were wiped out from under us.
local function prune_panels()
  for i = #panels, 1, -1 do
    if not panel_alive(panels[i]) then
      table.remove(panels, i)
    end
  end
  if last_panel and not panel_alive(last_panel) then
    last_panel = nil
  end
end

local function panel_for_buf(buf)
  for _, p in ipairs(panels) do
    if p.conv_buf == buf or p.prompt_buf == buf then
      return p
    end
  end
  return nil
end

local function find_panel_by_session(session_id)
  if not session_id then
    return nil
  end
  for _, p in ipairs(panels) do
    if p.session_id == session_id and panel_alive(p) then
      return p
    end
  end
  return nil
end

-- The panel commands act on: the one under the cursor, else the most
-- recently used, else any open one, else the newest alive one.
local function current_panel()
  prune_panels()
  local p = panel_for_buf(vim.api.nvim_get_current_buf())
  if p then
    return p
  end
  if last_panel then
    return last_panel
  end
  for _, q in ipairs(panels) do
    if panel_open(q) then
      return q
    end
  end
  return panels[#panels]
end

local function panel_index(p)
  for i, q in ipairs(panels) do
    if q == p then
      return i
    end
  end
  return 0
end

----------------------------------------------------------------------
-- low-level buffer helpers
----------------------------------------------------------------------

local function set_lines(p, start, finish, lines)
  if not buf_valid(p.conv_buf) then
    return
  end
  vim.bo[p.conv_buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.conv_buf, start, finish, false, lines)
  vim.bo[p.conv_buf].modifiable = false
end

local function scroll_to_bottom(p)
  if win_valid(p.conv_win) and buf_valid(p.conv_buf) then
    local count = vim.api.nvim_buf_line_count(p.conv_buf)
    pcall(vim.api.nvim_win_set_cursor, p.conv_win, { count, 0 })
  end
end

-- Append lines to the end of the conversation buffer.
local function append(p, lines)
  if not buf_valid(p.conv_buf) then
    return
  end
  local count = vim.api.nvim_buf_line_count(p.conv_buf)
  -- A fresh scratch buffer has a single empty line; overwrite it.
  if count == 1 and vim.api.nvim_buf_get_lines(p.conv_buf, 0, 1, false)[1] == "" then
    set_lines(p, 0, 1, lines)
  else
    set_lines(p, count, count, lines)
  end
  scroll_to_bottom(p)
end

----------------------------------------------------------------------
-- winbar / spinner
----------------------------------------------------------------------

local function winbar_text(p)
  local o = config.options
  local left
  if p.busy then
    local frame = o.ui.spinner[p.spinner.idx] or ""
    left = frame .. " thinking…"
  else
    left = " neocursor"
  end
  if #panels > 1 then
    left = left .. " [" .. panel_index(p) .. "]"
  end
  local sess
  if p.title and p.title ~= "" then
    sess = p.title
    if #sess > 24 then
      sess = sess:sub(1, 23) .. "…"
    end
    sess = "  · " .. sess
  else
    sess = p.session_id and "  · session" or "  · new"
  end
  local pending = #diff.pending(p.changes)
  local pend = pending > 0 and (" · " .. pending .. " pending") or ""
  return string.format("%%#Title#%s%%* · %s · model: %s%s%s",
    left,
    p.mode or o.default_mode,
    p.model or "auto",
    pend,
    sess)
end

local function update_winbar(p)
  if win_valid(p.conv_win) then
    vim.wo[p.conv_win].winbar = winbar_text(p)
  end
end

local function stop_spinner(p)
  if p.spinner.timer then
    p.spinner.timer:stop()
    if not p.spinner.timer:is_closing() then
      p.spinner.timer:close()
    end
    p.spinner.timer = nil
  end
end

local function start_spinner(p)
  stop_spinner(p)
  p.spinner.idx = 1
  local timer = uv.new_timer()
  p.spinner.timer = timer
  timer:start(0, 100, vim.schedule_wrap(function()
    if not p.busy then
      stop_spinner(p)
      return
    end
    local frames = config.options.ui.spinner
    p.spinner.idx = (p.spinner.idx % #frames) + 1
    update_winbar(p)
  end))
end

----------------------------------------------------------------------
-- rendering turns
----------------------------------------------------------------------

local function render_user(p, question, label)
  local lines = { "## You", "" }
  for _, l in ipairs(vim.split(question, "\n", { plain = true })) do
    table.insert(lines, l)
  end
  if label then
    table.insert(lines, "")
    table.insert(lines, "_context: `" .. label .. "`_")
  end
  table.insert(lines, "")
  append(p, lines)
end

local function start_assistant_block(p)
  p.stream_text = ""
  p.rendered_any = false
  append(p, { "## Cursor · " .. (p.mode or config.options.default_mode), "" })
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
end

local function render_stream(p)
  local lines = vim.split(p.stream_text, "\n", { plain = true })
  set_lines(p, p.assistant_start, -1, lines)
  scroll_to_bottom(p)
end

local function append_stream(p, delta)
  if delta == nil or delta == "" then
    return
  end
  p.rendered_any = true
  p.stream_text = p.stream_text .. delta
  render_stream(p)
end

-- "Freeze" the current streamed text so following content (tool output) is
-- appended after it, and subsequent deltas start a fresh segment.
local function commit_stream(p)
  p.stream_text = ""
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
end

local function render_note(p, text)
  append(p, { "_" .. text .. "_", "" })
end

local function render_tool_note(p, name, payload)
  commit_stream(p)
  p.rendered_any = true
  append(p, { "_⚙ " .. diff.tool_summary(name, payload) .. "_", "" })
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
end

local function render_tool_change(p, change)
  commit_stream(p)
  p.rendered_any = true
  local k = config.options.keymaps
  local counts = string.format("(+%s −%s)", change.added or "?", change.removed or "?")
  append(p, { "", "**" .. diff.status_icon(change) .. " edited `" .. change.rel .. "`** " .. counts, "" })
  if change.diff and change.diff ~= "" then
    append(p, { "```diff" })
    append(p, diff.diff_hunks(change.diff))
    append(p, { "```" })
  end
  append(p, {
    string.format(
      "_%s · `%s` review · `%s` accept · `%s` reject_",
      diff.status_label(change),
      k.review or k.diff or "<C-y>",
      k.accept or "<C-a>",
      k.reject or "<C-x>"
    ),
    "",
  })
  p.assistant_start = vim.api.nvim_buf_line_count(p.conv_buf)
  diff.reload_file(change.path)
end

local function render_error(p, msg)
  append(p, { "", "> **error:** " .. (msg or "unknown error"), "" })
end

local function finish_assistant_block(p, result_obj)
  local o = config.options
  -- Fallback: nothing rendered at all but we have a final result string.
  if not p.rendered_any and result_obj and type(result_obj.result) == "string" and result_obj.result ~= "" then
    append_stream(p, result_obj.result)
  end
  if o.ui.show_usage and result_obj and result_obj.usage then
    local u = result_obj.usage
    local secs = result_obj.duration_ms and string.format("%.1fs", result_obj.duration_ms / 1000) or nil
    local bits = {}
    if u.outputTokens then
      table.insert(bits, u.outputTokens .. " out")
    end
    if u.inputTokens then
      table.insert(bits, u.inputTokens .. " in")
    end
    if secs then
      table.insert(bits, secs)
    end
    if #bits > 0 then
      append(p, { "", "_" .. table.concat(bits, " · ") .. "_" })
    end
  end
  append(p, { "", "---", "" })
end

----------------------------------------------------------------------
-- session persistence
----------------------------------------------------------------------

-- Record the panel's session in the registry and snapshot the rendered
-- conversation so it can be listed and resumed later.
local function persist_session(p)
  if not p.session_id or p.session_id == "" then
    return
  end
  sessions.record({
    id = p.session_id,
    title = p.title,
    cwd = p.cwd or vim.fn.getcwd(),
    mode = p.mode,
    model = p.model,
    turns = p.turns,
  })
  if buf_valid(p.conv_buf) then
    sessions.save_transcript(p.session_id, vim.api.nvim_buf_get_lines(p.conv_buf, 0, -1, false))
  end
end

----------------------------------------------------------------------
-- event handling
----------------------------------------------------------------------

local function on_event(p, obj)
  local o = config.options
  if obj.type == "system" and obj.subtype == "init" then
    p.session_id = obj.session_id or p.session_id
  elseif obj.type == "assistant" then
    local content = obj.message and obj.message.content or {}
    for _, item in ipairs(content) do
      if item.type == "text" then
        -- Streaming deltas carry timestamp_ms but NOT model_call_id. The
        -- consolidated messages carry model_call_id (intermediate) or neither
        -- (final), so we render only true deltas to avoid duplication.
        if obj.timestamp_ms and not obj.model_call_id then
          append_stream(p, item.text or "")
        end
      elseif item.type == "thinking" then
        if o.ui.show_thinking and obj.timestamp_ms and not obj.model_call_id then
          append_stream(p, item.text or item.thinking or "")
        end
      end
    end
  elseif obj.type == "tool_call" then
    -- Tool calls are top-level events. Render on completion so results (and
    -- diffs) are available.
    if obj.subtype == "completed" then
      local name, payload = diff.parse_tool(obj)
      if name then
        local change = diff.change_from_payload(name, payload)
        if change then
          table.insert(p.changes, change)
          render_tool_change(p, change)
        else
          render_tool_note(p, name, payload)
        end
      end
    end
  elseif obj.type == "result" then
    p.got_result = true
    p.session_id = obj.session_id or p.session_id
    finish_assistant_block(p, obj)
    if obj.is_error then
      render_error(p, type(obj.result) == "string" and obj.result or "agent reported an error")
    end
  elseif obj.type == "error" then
    render_error(p, obj.message or obj.error or "agent error")
  end
end

local function on_done(p, code, stderr)
  p.busy = false
  local job_failed = (code ~= 0)
  if job_failed and not p.got_result then
    local msg = stderr ~= "" and stderr or ("cursor-agent exited with code " .. tostring(code))
    render_error(p, msg)
  end
  p.job = nil
  stop_spinner(p)
  update_winbar(p)
  persist_session(p)
end

----------------------------------------------------------------------
-- submit
----------------------------------------------------------------------

local function submit_panel(p)
  if not panel_open(p) then
    return
  end
  if p.busy then
    vim.notify("neocursor: still responding (use stop to cancel)", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(p.prompt_buf, 0, -1, false)
  local question = vim.trim(table.concat(lines, "\n"))
  if question == "" then
    return
  end

  last_panel = p

  -- Clear the prompt input.
  vim.bo[p.prompt_buf].modifiable = true
  vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })

  local exclude = {}
  for _, q in ipairs(panels) do
    if q.conv_buf then exclude[q.conv_buf] = true end
    if q.prompt_buf then exclude[q.prompt_buf] = true end
  end
  local origin = context.current_origin(exclude)
  local selection = p.pending_selection
  p.pending_selection = nil

  local built = context.build(question, origin, selection)

  if not p.title then
    p.title = sessions.title_from_prompt(question)
  end

  render_user(p, question, built.label)
  start_assistant_block(p)

  p.busy = true
  p.got_result = false
  p.turns = p.turns + 1
  p.cwd = vim.fn.getcwd()
  start_spinner(p)
  update_winbar(p)

  p.job = agent.run({
    prompt = built.prompt,
    mode = p.mode,
    model = p.model,
    session_id = p.session_id,
    cwd = p.cwd,
    on_event = function(obj)
      on_event(p, obj)
    end,
    on_done = function(code, stderr)
      on_done(p, code, stderr)
    end,
  })
end

function M.submit()
  local p = current_panel()
  if p then
    submit_panel(p)
  end
end

function M.stop()
  local p = current_panel()
  if p and p.job then
    agent.stop(p.job)
    render_note(p, "⏹ stopped")
  end
end

----------------------------------------------------------------------
-- mode / chat management
----------------------------------------------------------------------

function M.toggle_mode()
  local p = current_panel()
  if not p then
    return
  end
  local cycle = config.options.mode_cycle
  if not cycle or #cycle == 0 then
    return
  end
  local cur = p.mode or config.options.default_mode
  local idx = 1
  for i, m in ipairs(cycle) do
    if m == cur then
      idx = i
      break
    end
  end
  p.mode = cycle[(idx % #cycle) + 1]
  update_winbar(p)
  vim.notify("neocursor: mode → " .. p.mode, vim.log.levels.INFO)
end

-- Pick a model via cursor-agent --list-models + vim.ui.select.
-- Sets the model for the current panel only, so parallel panels can use
-- different models.
function M.pick_model()
  local p = current_panel()
  vim.notify("neocursor: loading models…", vim.log.levels.INFO)
  agent.list_models(function(models, code)
    if code ~= 0 or #models == 0 then
      vim.notify("neocursor: could not list models (is cursor-agent installed?)", vim.log.levels.ERROR)
      return
    end
    local current = (p and p.model) or "auto"
    vim.ui.select(models, {
      prompt = "neocursor: select model",
      format_item = function(m)
        local mark = (m.id == current) and "● " or "  "
        return mark .. m.label .. "  (" .. m.id .. ")"
      end,
    }, function(choice)
      if not choice then
        return
      end
      if p then
        p.model = (choice.id == "auto") and nil or choice.id
        update_winbar(p)
      end
      vim.notify("neocursor: model → " .. choice.label, vim.log.levels.INFO)
    end)
  end)
end

-- View the file changes the agent made this session as a side-by-side diff.
function M.show_changes()
  local p = current_panel()
  if not p or #p.changes == 0 then
    vim.notify("neocursor: no file changes this session", vim.log.levels.INFO)
    return
  end
  if #p.changes == 1 then
    diff.show(p.changes[1])
    return
  end
  vim.ui.select(p.changes, {
    prompt = "neocursor: view change",
    format_item = function(c)
      return string.format("%s %s  (+%s −%s)", diff.status_icon(c), c.rel, c.added or "?", c.removed or "?")
    end,
  }, function(choice)
    if choice then
      diff.show(choice)
    end
  end)
end

local function pick_pending(prompt, cb)
  local p = current_panel()
  local pending = p and diff.pending(p.changes) or {}
  if #pending == 0 then
    vim.notify("neocursor: no pending changes to review", vim.log.levels.INFO)
    return
  end
  if #pending == 1 then
    cb(pending[1])
    return
  end
  vim.ui.select(pending, {
    prompt = prompt,
    format_item = function(c)
      return string.format("%s %s  (+%s −%s)", diff.status_icon(c), c.rel, c.added or "?", c.removed or "?")
    end,
  }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

function M.accept_change(change)
  if not change or change.status ~= "pending" then
    return false
  end
  local ok, err = diff.accept(change)
  if not ok then
    vim.notify("neocursor: accept failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  local p = current_panel()
  if p then
    render_note(p, "✓ accepted `" .. change.rel .. "`")
    update_winbar(p)
  end
  vim.notify("neocursor: accepted " .. change.rel, vim.log.levels.INFO)
  return true
end

function M.reject_change(change)
  if not change or change.status ~= "pending" then
    return false
  end
  local ok, err = diff.reject(change)
  if not ok then
    vim.notify("neocursor: reject failed: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  local p = current_panel()
  if p then
    render_note(p, "✗ rejected `" .. change.rel .. "` (file restored)")
    update_winbar(p)
  end
  vim.notify("neocursor: rejected " .. change.rel .. " (reverted)", vim.log.levels.INFO)
  return true
end

function M.accept_changes()
  pick_pending("neocursor: accept change", function(c)
    M.accept_change(c)
  end)
end

function M.reject_changes()
  pick_pending("neocursor: reject change", function(c)
    M.reject_change(c)
  end)
end

function M.review_changes()
  pick_pending("neocursor: review change", function(change)
    diff.review(change, {
      on_accept = function(c)
        M.accept_change(c)
      end,
      on_reject = function(c)
        M.reject_change(c)
      end,
    })
  end)
end

function M.new_chat()
  local p = current_panel()
  if not p then
    return
  end
  if p.busy and p.job then
    agent.stop(p.job)
    p.busy = false
    stop_spinner(p)
  end
  persist_session(p)
  p.session_id = nil
  p.title = nil
  p.turns = 0
  p.got_result = false
  p.stream_text = ""
  p.changes = {}
  if buf_valid(p.conv_buf) then
    set_lines(p, 0, -1, {})
  end
  M.render_greeting(p)
  update_winbar(p)
end

function M.render_greeting(p)
  p = p or current_panel()
  if not p then
    return
  end
  local o = config.options
  append(p, {
    "# neocursor",
    "",
    "Cursor agent inside Neovim. Type below and press `" .. (o.keymaps.submit or "<C-s>") .. "` to send.",
    "",
    "- `" .. (o.keymaps.new_chat or "<C-n>") .. "` new chat   ",
    "- `" .. (o.keymaps.sessions or "<M-s>") .. "` sessions (view / resume)   ",
    "- `" .. (o.keymaps.new_panel or "<M-n>") .. "` new panel (parallel session)   ",
    "- `" .. (o.keymaps.toggle_mode or "<M-t>") .. "` switch mode (" .. table.concat(o.mode_cycle, " / ") .. ")   ",
    "- `" .. (o.keymaps.model or "<C-g>") .. "` pick model   ",
    "- `" .. (o.keymaps.review or o.keymaps.diff or "<C-y>") .. "` review changes   ",
    "- `" .. (o.keymaps.accept or "<C-a>") .. "` accept · `" .. (o.keymaps.reject or "<C-x>") .. "` reject   ",
    "- `:NeocursorAsk` (visual) ask about selected lines",
    "",
    "---",
    "",
  })
end

----------------------------------------------------------------------
-- window construction
----------------------------------------------------------------------

local function compute_width()
  local w = config.options.ui.width
  if w <= 1 then
    return math.max(30, math.floor(vim.o.columns * w))
  end
  return math.floor(w)
end

local function set_panel_buf_opts(buf, ft)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = ft
end

local function apply_panel_keymaps(p)
  local k = config.options.keymaps
  local function map(buf, modes, lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  -- Prompt buffer: submit & control.
  map(p.prompt_buf, { "n", "i" }, k.submit, function()
    submit_panel(p)
  end, "neocursor: submit")
  map(p.prompt_buf, "n", k.submit_normal, function()
    submit_panel(p)
  end, "neocursor: submit")
  map(p.prompt_buf, { "n", "i" }, k.stop, function()
    if p.job then
      agent.stop(p.job)
      render_note(p, "⏹ stopped")
    end
  end, "neocursor: stop")

  for _, buf in ipairs({ p.prompt_buf, p.conv_buf }) do
    local modes = (buf == p.prompt_buf) and { "n", "i" } or "n"
    map(buf, modes, k.new_chat, function()
      M.new_chat()
    end, "neocursor: new chat")
    map(buf, modes, k.toggle_mode, function()
      M.toggle_mode()
    end, "neocursor: toggle mode")
    map(buf, modes, k.model, function()
      M.pick_model()
    end, "neocursor: pick model")
    map(buf, modes, k.sessions, function()
      M.pick_session()
    end, "neocursor: sessions")
    map(buf, modes, k.new_panel, function()
      M.open_new_panel()
    end, "neocursor: new panel")
    map(buf, "n", k.review or k.diff, function()
      M.review_changes()
    end, "neocursor: review changes")
    map(buf, "n", k.accept, function()
      M.accept_changes()
    end, "neocursor: accept change")
    map(buf, "n", k.reject, function()
      M.reject_changes()
    end, "neocursor: reject change")
    map(buf, "n", k.close, function()
      M.close_panel(p)
    end, "neocursor: close panel")
  end

  map(p.conv_buf, "n", k.focus_prompt, function()
    M.focus_prompt(p)
  end, "neocursor: focus prompt")
end

local function setup_panel_autocmds(p)
  p.augroup = vim.api.nvim_create_augroup("NeocursorPanel" .. p.id, { clear = true })

  -- Track the most recently used panel.
  vim.api.nvim_create_autocmd("BufEnter", {
    group = p.augroup,
    callback = function(ev)
      if ev.buf == p.conv_buf or ev.buf == p.prompt_buf then
        last_panel = p
      end
    end,
  })

  -- If one of the pair of windows is closed directly (:q), close its sibling
  -- so half-panels are never left behind.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = p.augroup,
    callback = function(ev)
      local w = tonumber(ev.match)
      if p.closing or (w ~= p.conv_win and w ~= p.prompt_win) then
        return
      end
      p.closing = true
      vim.schedule(function()
        if win_valid(p.prompt_win) then
          pcall(vim.api.nvim_win_close, p.prompt_win, true)
        end
        if win_valid(p.conv_win) then
          pcall(vim.api.nvim_win_close, p.conv_win, true)
        end
        p.conv_win = nil
        p.prompt_win = nil
        p.closing = false
      end)
    end,
  })
end

local function win_opts(win, is_prompt)
  local o = config.options
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = o.ui.wrap
  vim.wo[win].linebreak = o.ui.wrap
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].winfixwidth = true
  if is_prompt then
    vim.wo[win].winbar = "%#Comment#  prompt — type your question %*"
  end
end

-- Distribute the sidebar column height between the open panels: every prompt
-- gets its configured height and the conversations share the rest.
local function relayout()
  local open = {}
  for _, q in ipairs(panels) do
    if panel_open(q) then
      table.insert(open, q)
    end
  end
  if #open < 2 then
    return
  end
  local o = config.options
  local total = 0
  for _, q in ipairs(open) do
    total = total + vim.api.nvim_win_get_height(q.conv_win) + vim.api.nvim_win_get_height(q.prompt_win)
  end
  local conv_h = math.max(3, math.floor(total / #open) - o.ui.prompt_height - 1)
  for _, q in ipairs(open) do
    pcall(vim.api.nvim_win_set_height, q.conv_win, conv_h)
    pcall(vim.api.nvim_win_set_height, q.prompt_win, o.ui.prompt_height)
  end
end

-- Open (or reopen) the windows for a panel. If another panel is already open,
-- the new panel stacks below it inside the same sidebar column; otherwise a
-- fresh sidebar vsplit is created.
local function open_windows(p)
  if panel_open(p) then
    return
  end

  local o = config.options
  local anchor = nil
  for _, q in ipairs(panels) do
    if q ~= p and panel_open(q) then
      anchor = q
    end
  end

  -- Stack below an existing panel when the column is tall enough for two
  -- panels; otherwise fall back to a fresh sidebar column.
  local stacked = false
  if anchor then
    local total = vim.api.nvim_win_get_height(anchor.conv_win) + vim.api.nvim_win_get_height(anchor.prompt_win)
    local min_panel_h = o.ui.prompt_height + 6
    if total >= 2 * min_panel_h then
      vim.api.nvim_set_current_win(anchor.prompt_win)
      pcall(vim.api.nvim_win_set_height, anchor.prompt_win, math.max(4, math.floor(total / 2)))
      stacked = pcall(vim.cmd, "belowright split")
    end
  end
  if not stacked then
    vim.cmd(o.ui.position == "left" and "topleft vsplit" or "botright vsplit")
  end
  p.conv_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(p.conv_win, p.conv_buf)
  if not stacked then
    vim.api.nvim_win_set_width(p.conv_win, compute_width())
  end

  -- Prompt window below the conversation, inside the same column.
  vim.cmd("belowright split")
  p.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(p.prompt_win, p.prompt_buf)
  pcall(vim.api.nvim_win_set_height, p.prompt_win, o.ui.prompt_height)

  win_opts(p.conv_win, false)
  win_opts(p.prompt_win, true)
  -- Refresh every winbar: panel indices are shown once there is more than one.
  for _, q in ipairs(panels) do
    update_winbar(q)
  end
  relayout()
end

local function create_panel()
  local p = new_panel_state()
  p.mode = config.options.default_mode
  if config.options.model and config.options.model ~= "" then
    p.model = config.options.model
  end

  p.conv_buf = vim.api.nvim_create_buf(false, true)
  set_panel_buf_opts(p.conv_buf, "markdown")
  vim.bo[p.conv_buf].modifiable = false

  p.prompt_buf = vim.api.nvim_create_buf(false, true)
  set_panel_buf_opts(p.prompt_buf, "markdown")
  vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })

  table.insert(panels, p)
  apply_panel_keymaps(p)
  setup_panel_autocmds(p)
  open_windows(p)
  M.render_greeting(p)
  last_panel = p
  return p
end

function M.is_open()
  prune_panels()
  for _, p in ipairs(panels) do
    if panel_open(p) then
      return true
    end
  end
  return false
end

function M.panel_count()
  prune_panels()
  return #panels
end

-- Session id of the current panel (nil for a fresh chat). Handy for
-- statuslines and tests.
function M.current_session_id()
  local p = current_panel()
  return p and p.session_id or nil
end

function M.focus_prompt(p)
  p = p or current_panel()
  if p and win_valid(p.prompt_win) then
    vim.api.nvim_set_current_win(p.prompt_win)
    last_panel = p
    vim.cmd("startinsert")
  end
end

function M.open()
  local p = current_panel()
  if p then
    if not panel_open(p) then
      open_windows(p)
    end
    M.focus_prompt(p)
    return p
  end
  p = create_panel()
  M.focus_prompt(p)
  return p
end

-- Open an additional, independent panel (its own session/mode/model/job),
-- stacked below any panel already visible.
function M.open_new_panel()
  local p = create_panel()
  M.focus_prompt(p)
  return p
end

-- Close a single panel's windows (buffers/state are kept, so it can be
-- reopened and any in-flight job keeps streaming into its buffer).
function M.close_panel(p)
  p = p or current_panel()
  if not p then
    return
  end
  stop_spinner(p)
  p.closing = true
  if win_valid(p.prompt_win) then
    pcall(vim.api.nvim_win_close, p.prompt_win, true)
  end
  if win_valid(p.conv_win) then
    pcall(vim.api.nvim_win_close, p.conv_win, true)
  end
  p.conv_win = nil
  p.prompt_win = nil
  p.closing = false
end

-- Close every open panel.
function M.close()
  for _, p in ipairs(panels) do
    if panel_open(p) then
      M.close_panel(p)
    end
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

----------------------------------------------------------------------
-- sessions: view / resume
----------------------------------------------------------------------

-- Resume a session entry ({ id, title?, mode?, model?, turns? }).
-- opts.new_panel: open in a fresh panel instead of reusing the current one.
function M.resume(sess, opts)
  opts = opts or {}
  if not sess or not sess.id or sess.id == "" then
    return
  end

  local p
  if not opts.new_panel then
    p = current_panel()
    -- Don't hijack a panel that is mid-response.
    if p and p.busy then
      p = nil
    end
  end
  if p then
    if not panel_open(p) then
      open_windows(p)
    end
    persist_session(p)
  else
    p = create_panel()
  end

  p.session_id = sess.id
  p.title = sess.title
  p.mode = sess.mode or p.mode or config.options.default_mode
  p.model = sess.model or p.model
  p.changes = {}
  p.turns = sess.turns or 0
  p.stream_text = ""
  p.pending_selection = nil

  set_lines(p, 0, -1, {})
  local transcript = sessions.load_transcript(sess.id)
  if transcript then
    set_lines(p, 0, -1, transcript)
    append(p, { "", "_↩ resumed session — follow-ups continue where it left off_", "" })
  else
    append(p, {
      "# neocursor",
      "",
      "_↩ resumed session `" .. sess.id .. "`_",
      "",
      "_No local transcript for this session (it was likely started outside",
      "Neovim), but the agent still has the full history — just keep asking._",
      "",
      "---",
      "",
    })
  end
  scroll_to_bottom(p)
  update_winbar(p)
  M.focus_prompt(p)
  return p
end

-- Pick a session from the registry (+ discovered CLI sessions) and resume it.
-- opts.new_panel: resume into a new panel (parallel session).
function M.pick_session(opts)
  opts = opts or {}
  local list = sessions.list(vim.fn.getcwd())
  if #list == 0 then
    vim.notify("neocursor: no previous sessions for this directory", vim.log.levels.INFO)
    return
  end
  vim.ui.select(list, {
    prompt = "neocursor: sessions (resume)",
    format_item = function(s)
      local mark = find_panel_by_session(s.id) and "● " or "  "
      return mark .. sessions.format(s)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local existing = find_panel_by_session(choice.id)
    if existing and not opts.new_panel then
      -- Already open in a panel: just focus it.
      if not panel_open(existing) then
        open_windows(existing)
      end
      M.focus_prompt(existing)
      return
    end
    M.resume(choice, opts)
  end)
end

-- Resume the most recent session for this cwd, or a specific session id.
function M.resume_last(id, opts)
  local sess
  if id and id ~= "" then
    sess = sessions.get(id) or { id = id }
  else
    sess = sessions.list(vim.fn.getcwd())[1]
  end
  if not sess then
    vim.notify("neocursor: no previous sessions for this directory", vim.log.levels.INFO)
    return
  end
  local existing = find_panel_by_session(sess.id)
  if existing then
    if not panel_open(existing) then
      open_windows(existing)
    end
    M.focus_prompt(existing)
    return existing
  end
  return M.resume(sess, opts)
end

-- Attach a selection to the next submitted prompt and open the panel.
-- selection: table from context.selection_from_range (or nil).
-- question: optional; if given, submit immediately.
function M.ask(selection, question)
  local p = M.open()
  if not p then
    return
  end
  p.pending_selection = selection
  if question and question ~= "" then
    vim.bo[p.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, vim.split(question, "\n", { plain = true }))
    submit_panel(p)
  end
end

return M
