-- neocursor: the sidebar chat UI (conversation + prompt windows) and streaming
-- render of cursor-agent responses.
local config = require("neocursor.config")
local agent = require("neocursor.agent")
local context = require("neocursor.context")
local diff = require("neocursor.diff")

local M = {}

local uv = vim.uv or vim.loop

-- Module-level singleton state for the panel.
local state = {
  conv_buf = nil,
  conv_win = nil,
  prompt_buf = nil,
  prompt_win = nil,
  session_id = nil,
  mode = nil,
  model = nil,            -- currently selected model id (nil => auto)
  job = nil,
  busy = false,
  got_result = false,
  rendered_any = false,   -- did this turn render any text/tool output?
  stream_text = "",
  assistant_start = 0,   -- 0-based line where the streaming answer begins
  pending_selection = nil,
  changes = {},          -- file changes made by the agent this session
  spinner = { timer = nil, idx = 1 },
}

----------------------------------------------------------------------
-- low-level buffer helpers
----------------------------------------------------------------------

local function buf_valid(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function win_valid(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function set_lines(buf, start, finish, lines)
  if not buf_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, finish, false, lines)
  vim.bo[buf].modifiable = false
end

local function scroll_to_bottom()
  if win_valid(state.conv_win) and buf_valid(state.conv_buf) then
    local count = vim.api.nvim_buf_line_count(state.conv_buf)
    pcall(vim.api.nvim_win_set_cursor, state.conv_win, { count, 0 })
  end
end

-- Append lines to the end of the conversation buffer.
local function append(lines)
  if not buf_valid(state.conv_buf) then
    return
  end
  local count = vim.api.nvim_buf_line_count(state.conv_buf)
  -- A fresh scratch buffer has a single empty line; overwrite it.
  if count == 1 and vim.api.nvim_buf_get_lines(state.conv_buf, 0, 1, false)[1] == "" then
    set_lines(state.conv_buf, 0, 1, lines)
  else
    set_lines(state.conv_buf, count, count, lines)
  end
  scroll_to_bottom()
end

----------------------------------------------------------------------
-- winbar / spinner
----------------------------------------------------------------------

local function winbar_text()
  local o = config.options
  local left
  if state.busy then
    local frame = o.ui.spinner[state.spinner.idx] or ""
    left = frame .. " thinking…"
  else
    left = " neocursor"
  end
  local sess = state.session_id and "  · session" or "  · new"
  local pending = #diff.pending(state.changes)
  local pend = pending > 0 and (" · " .. pending .. " pending") or ""
  return string.format("%%#Title#%s%%* · %s · model: %s%s%s",
    left,
    state.mode or o.default_mode,
    state.model or "auto",
    pend,
    sess)
end

local function update_winbar()
  if win_valid(state.conv_win) then
    vim.wo[state.conv_win].winbar = winbar_text()
  end
end

local function stop_spinner()
  if state.spinner.timer then
    state.spinner.timer:stop()
    if not state.spinner.timer:is_closing() then
      state.spinner.timer:close()
    end
    state.spinner.timer = nil
  end
end

local function start_spinner()
  stop_spinner()
  state.spinner.idx = 1
  local timer = uv.new_timer()
  state.spinner.timer = timer
  timer:start(0, 100, vim.schedule_wrap(function()
    if not state.busy then
      stop_spinner()
      return
    end
    local frames = config.options.ui.spinner
    state.spinner.idx = (state.spinner.idx % #frames) + 1
    update_winbar()
  end))
end

----------------------------------------------------------------------
-- rendering turns
----------------------------------------------------------------------

local function render_user(question, label)
  local lines = { "## You", "" }
  for _, l in ipairs(vim.split(question, "\n", { plain = true })) do
    table.insert(lines, l)
  end
  if label then
    table.insert(lines, "")
    table.insert(lines, "_context: `" .. label .. "`_")
  end
  table.insert(lines, "")
  append(lines)
end

local function start_assistant_block()
  state.stream_text = ""
  state.rendered_any = false
  append({ "## Cursor · " .. (state.mode or config.options.default_mode), "" })
  state.assistant_start = vim.api.nvim_buf_line_count(state.conv_buf)
end

local function render_stream()
  local lines = vim.split(state.stream_text, "\n", { plain = true })
  set_lines(state.conv_buf, state.assistant_start, -1, lines)
  scroll_to_bottom()
end

local function append_stream(delta)
  if delta == nil or delta == "" then
    return
  end
  state.rendered_any = true
  state.stream_text = state.stream_text .. delta
  render_stream()
end

-- "Freeze" the current streamed text so following content (tool output) is
-- appended after it, and subsequent deltas start a fresh segment.
local function commit_stream()
  state.stream_text = ""
  state.assistant_start = vim.api.nvim_buf_line_count(state.conv_buf)
end

local function render_note(text)
  append({ "_" .. text .. "_", "" })
end

local function render_tool_note(name, payload)
  commit_stream()
  state.rendered_any = true
  append({ "_⚙ " .. diff.tool_summary(name, payload) .. "_", "" })
  state.assistant_start = vim.api.nvim_buf_line_count(state.conv_buf)
end

local function render_tool_change(change)
  commit_stream()
  state.rendered_any = true
  local k = config.options.keymaps
  local counts = string.format("(+%s −%s)", change.added or "?", change.removed or "?")
  append({ "", "**" .. diff.status_icon(change) .. " edited `" .. change.rel .. "`** " .. counts, "" })
  if change.diff and change.diff ~= "" then
    append({ "```diff" })
    append(diff.diff_hunks(change.diff))
    append({ "```" })
  end
  append({
    string.format(
      "_%s · `%s` review · `%s` accept · `%s` reject_",
      diff.status_label(change),
      k.review or k.diff or "<C-y>",
      k.accept or "<C-a>",
      k.reject or "<C-x>"
    ),
    "",
  })
  state.assistant_start = vim.api.nvim_buf_line_count(state.conv_buf)
  diff.reload_file(change.path)
end

local function render_error(msg)
  append({ "", "> **error:** " .. (msg or "unknown error"), "" })
end

local function finish_assistant_block(result_obj)
  local o = config.options
  -- Fallback: nothing rendered at all but we have a final result string.
  if not state.rendered_any and result_obj and type(result_obj.result) == "string" and result_obj.result ~= "" then
    append_stream(result_obj.result)
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
      append({ "", "_" .. table.concat(bits, " · ") .. "_" })
    end
  end
  append({ "", "---", "" })
end

----------------------------------------------------------------------
-- event handling
----------------------------------------------------------------------

local function on_event(obj)
  local o = config.options
  if obj.type == "system" and obj.subtype == "init" then
    state.session_id = obj.session_id or state.session_id
  elseif obj.type == "assistant" then
    local content = obj.message and obj.message.content or {}
    for _, item in ipairs(content) do
      if item.type == "text" then
        -- Streaming deltas carry timestamp_ms but NOT model_call_id. The
        -- consolidated messages carry model_call_id (intermediate) or neither
        -- (final), so we render only true deltas to avoid duplication.
        if obj.timestamp_ms and not obj.model_call_id then
          append_stream(item.text or "")
        end
      elseif item.type == "thinking" then
        if o.ui.show_thinking and obj.timestamp_ms and not obj.model_call_id then
          append_stream(item.text or item.thinking or "")
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
          table.insert(state.changes, change)
          render_tool_change(change)
        else
          render_tool_note(name, payload)
        end
      end
    end
  elseif obj.type == "result" then
    state.got_result = true
    state.session_id = obj.session_id or state.session_id
    finish_assistant_block(obj)
    if obj.is_error then
      render_error(type(obj.result) == "string" and obj.result or "agent reported an error")
    end
  elseif obj.type == "error" then
    render_error(obj.message or obj.error or "agent error")
  end
end

local function on_done(code, stderr)
  state.busy = false
  local job_failed = (code ~= 0)
  if job_failed and not state.got_result then
    local msg = stderr ~= "" and stderr or ("cursor-agent exited with code " .. tostring(code))
    render_error(msg)
  end
  state.job = nil
  stop_spinner()
  update_winbar()
end

----------------------------------------------------------------------
-- submit
----------------------------------------------------------------------

function M.submit()
  if not M.is_open() then
    return
  end
  if state.busy then
    vim.notify("neocursor: still responding (use stop to cancel)", vim.log.levels.WARN)
    return
  end

  local lines = vim.api.nvim_buf_get_lines(state.prompt_buf, 0, -1, false)
  local question = vim.trim(table.concat(lines, "\n"))
  if question == "" then
    return
  end

  -- Clear the prompt input.
  vim.bo[state.prompt_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { "" })

  local exclude = {}
  if state.conv_buf then exclude[state.conv_buf] = true end
  if state.prompt_buf then exclude[state.prompt_buf] = true end
  local origin = context.current_origin(exclude)
  local selection = state.pending_selection
  state.pending_selection = nil

  local built = context.build(question, origin, selection)

  render_user(question, built.label)
  start_assistant_block()

  state.busy = true
  state.got_result = false
  start_spinner()
  update_winbar()

  state.job = agent.run({
    prompt = built.prompt,
    mode = state.mode,
    session_id = state.session_id,
    cwd = vim.fn.getcwd(),
    on_event = on_event,
    on_done = on_done,
  })
end

function M.stop()
  if state.job then
    agent.stop(state.job)
    render_note("⏹ stopped")
  end
end

----------------------------------------------------------------------
-- mode / chat management
----------------------------------------------------------------------

function M.toggle_mode()
  local cycle = config.options.mode_cycle
  if not cycle or #cycle == 0 then
    return
  end
  local cur = state.mode or config.options.default_mode
  local idx = 1
  for i, m in ipairs(cycle) do
    if m == cur then
      idx = i
      break
    end
  end
  state.mode = cycle[(idx % #cycle) + 1]
  update_winbar()
  vim.notify("neocursor: mode → " .. state.mode, vim.log.levels.INFO)
end

-- Pick a model via cursor-agent --list-models + vim.ui.select.
function M.pick_model()
  vim.notify("neocursor: loading models…", vim.log.levels.INFO)
  agent.list_models(function(models, code)
    if code ~= 0 or #models == 0 then
      vim.notify("neocursor: could not list models (is cursor-agent installed?)", vim.log.levels.ERROR)
      return
    end
    local current = state.model or "auto"
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
      state.model = choice.id
      config.options.model = (choice.id == "auto") and nil or choice.id
      update_winbar()
      vim.notify("neocursor: model → " .. choice.label, vim.log.levels.INFO)
    end)
  end)
end

-- View the file changes the agent made this session as a side-by-side diff.
function M.show_changes()
  if #state.changes == 0 then
    vim.notify("neocursor: no file changes this session", vim.log.levels.INFO)
    return
  end
  if #state.changes == 1 then
    diff.show(state.changes[1])
    return
  end
  vim.ui.select(state.changes, {
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
  local pending = diff.pending(state.changes)
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
  render_note("✓ accepted `" .. change.rel .. "`")
  update_winbar()
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
  render_note("✗ rejected `" .. change.rel .. "` (file restored)")
  update_winbar()
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
  if state.busy and state.job then
    agent.stop(state.job)
    state.busy = false
    stop_spinner()
  end
  state.session_id = nil
  state.got_result = false
  state.stream_text = ""
  state.changes = {}
  if buf_valid(state.conv_buf) then
    set_lines(state.conv_buf, 0, -1, {})
  end
  M.render_greeting()
  update_winbar()
end

function M.render_greeting()
  local o = config.options
  append({
    "# neocursor",
    "",
    "Cursor agent inside Neovim. Type below and press `" .. (o.keymaps.submit or "<C-s>") .. "` to send.",
    "",
    "- `" .. (o.keymaps.new_chat or "<C-n>") .. "` new chat   ",
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

local function apply_panel_keymaps()
  local k = config.options.keymaps
  local function map(buf, modes, lhs, rhs, desc)
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  -- Prompt buffer: submit & control.
  map(state.prompt_buf, { "n", "i" }, k.submit, function()
    M.submit()
  end, "neocursor: submit")
  map(state.prompt_buf, "n", k.submit_normal, function()
    M.submit()
  end, "neocursor: submit")
  map(state.prompt_buf, { "n", "i" }, k.new_chat, function()
    M.new_chat()
  end, "neocursor: new chat")
  map(state.prompt_buf, { "n", "i" }, k.toggle_mode, function()
    M.toggle_mode()
  end, "neocursor: toggle mode")
  map(state.prompt_buf, { "n", "i" }, k.stop, function()
    M.stop()
  end, "neocursor: stop")
  map(state.prompt_buf, { "n", "i" }, k.model, function()
    M.pick_model()
  end, "neocursor: pick model")
  map(state.prompt_buf, "n", k.review or k.diff, function()
    M.review_changes()
  end, "neocursor: review changes")
  map(state.prompt_buf, "n", k.accept, function()
    M.accept_changes()
  end, "neocursor: accept change")
  map(state.prompt_buf, "n", k.reject, function()
    M.reject_changes()
  end, "neocursor: reject change")
  map(state.prompt_buf, "n", k.close, function()
    M.close()
  end, "neocursor: close")

  -- Conversation buffer: navigation.
  map(state.conv_buf, "n", k.close, function()
    M.close()
  end, "neocursor: close")
  map(state.conv_buf, "n", k.new_chat, function()
    M.new_chat()
  end, "neocursor: new chat")
  map(state.conv_buf, "n", k.toggle_mode, function()
    M.toggle_mode()
  end, "neocursor: toggle mode")
  map(state.conv_buf, "n", k.model, function()
    M.pick_model()
  end, "neocursor: pick model")
  map(state.conv_buf, "n", k.review or k.diff, function()
    M.review_changes()
  end, "neocursor: review changes")
  map(state.conv_buf, "n", k.accept, function()
    M.accept_changes()
  end, "neocursor: accept change")
  map(state.conv_buf, "n", k.reject, function()
    M.reject_changes()
  end, "neocursor: reject change")
  map(state.conv_buf, "n", k.focus_prompt, function()
    M.focus_prompt()
  end, "neocursor: focus prompt")
end

function M.is_open()
  return win_valid(state.conv_win) and win_valid(state.prompt_win)
end

function M.focus_prompt()
  if win_valid(state.prompt_win) then
    vim.api.nvim_set_current_win(state.prompt_win)
    vim.cmd("startinsert")
  end
end

function M.open()
  if M.is_open() then
    M.focus_prompt()
    return
  end

  state.mode = state.mode or config.options.default_mode
  if state.model == nil and config.options.model and config.options.model ~= "" then
    state.model = config.options.model
  end
  local o = config.options

  -- Reuse buffers across open/close so the conversation persists.
  if not buf_valid(state.conv_buf) then
    state.conv_buf = vim.api.nvim_create_buf(false, true)
    set_panel_buf_opts(state.conv_buf, "markdown")
    vim.bo[state.conv_buf].modifiable = false
  end
  if not buf_valid(state.prompt_buf) then
    state.prompt_buf = vim.api.nvim_create_buf(false, true)
    set_panel_buf_opts(state.prompt_buf, "markdown")
    vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, { "" })
  end

  local width = compute_width()
  vim.cmd(o.ui.position == "left" and "topleft vsplit" or "botright vsplit")
  state.conv_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.conv_win, state.conv_buf)
  vim.api.nvim_win_set_width(state.conv_win, width)

  -- Prompt window below the conversation, inside the same column.
  vim.cmd("belowright split")
  state.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.prompt_win, state.prompt_buf)
  vim.api.nvim_win_set_height(state.prompt_win, o.ui.prompt_height)

  local function win_opts(win, is_prompt)
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
  win_opts(state.conv_win, false)
  win_opts(state.prompt_win, true)

  apply_panel_keymaps()
  update_winbar()

  -- Greeting only when the conversation is empty.
  local count = vim.api.nvim_buf_line_count(state.conv_buf)
  local first = vim.api.nvim_buf_get_lines(state.conv_buf, 0, 1, false)[1]
  if count <= 1 and (first == nil or first == "") then
    M.render_greeting()
  end

  M.focus_prompt()
end

function M.close()
  stop_spinner()
  if win_valid(state.prompt_win) then
    vim.api.nvim_win_close(state.prompt_win, true)
  end
  if win_valid(state.conv_win) then
    vim.api.nvim_win_close(state.conv_win, true)
  end
  state.conv_win = nil
  state.prompt_win = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

-- Attach a selection to the next submitted prompt and open the panel.
-- selection: table from context.selection_from_range (or nil).
-- question: optional; if given, submit immediately.
function M.ask(selection, question)
  state.pending_selection = selection
  M.open()
  if question and question ~= "" then
    vim.bo[state.prompt_buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.prompt_buf, 0, -1, false, vim.split(question, "\n", { plain = true }))
    M.submit()
  end
end

return M
