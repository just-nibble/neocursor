-- Headless smoke test for neocursor.
local failures = {}
local function check(cond, msg)
  if cond then
    print("PASS: " .. msg)
  else
    print("FAIL: " .. msg)
    table.insert(failures, msg)
  end
end

local cwd = vim.fn.getcwd()
vim.opt.runtimepath:append(cwd)

local neocursor = require("neocursor")
neocursor.setup({
  cmd = cwd .. "/tests/fake-cursor-agent",
  default_mode = "ask",
  sessions = {
    -- Keep test data out of the real stdpath("data") registry.
    dir = cwd .. "/tests/scratch/sessions-data",
    chats_dir = cwd .. "/tests/scratch/chats",
  },
})
vim.fn.delete(cwd .. "/tests/scratch/sessions-data", "rf")

local ui = require("neocursor.ui")

-- 1. Open the panel.
neocursor.open()
check(ui.is_open(), "panel opens (conversation + prompt windows)")

-- Find the panel buffers.
local conv_buf, prompt_buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "markdown" and vim.bo[b].buftype == "nofile" then
    local first = (vim.api.nvim_buf_get_lines(b, 0, 1, false))[1] or ""
    if first:match("^# neocursor") then
      conv_buf = b
    end
  end
end
check(conv_buf ~= nil, "conversation buffer found with greeting")

-- Identify the prompt window (the one that is not the conversation buffer).
local prompt_win
for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  local b = vim.api.nvim_win_get_buf(w)
  if b ~= conv_buf and vim.bo[b].buftype == "nofile" then
    prompt_win = w
    prompt_buf = b
  end
end
check(prompt_win ~= nil, "prompt window found")

-- 2. Type a question and submit.
vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "hi" })
vim.api.nvim_set_current_win(prompt_win)
ui.submit()

-- Wait for the (fake) job to complete.
local done = vim.wait(5000, function()
  local lines = vim.api.nvim_buf_get_lines(conv_buf, 0, -1, false)
  local text = table.concat(lines, "\n")
  return text:find("Done, changed hello to goodbye%.") ~= nil and text:find("30 out") ~= nil
end, 25)

local conv = table.concat(vim.api.nvim_buf_get_lines(conv_buf, 0, -1, false), "\n")
check(done, "response streamed and turn finalized")
check(conv:find("## You") ~= nil, "user turn rendered")
check(conv:find("## Cursor · ask") ~= nil, "assistant header rendered")
check(conv:find("I'll edit it%.") ~= nil, "pre-tool assistant text rendered")
check(conv:find("Done, changed hello to goodbye%.") ~= nil, "post-tool assistant text rendered")
-- The consolidated messages (model_call_id or final) must NOT duplicate text.
local _, dup = conv:gsub("Done, changed hello to goodbye%.", "")
check(dup == 1, "final answer not duplicated (got " .. dup .. " occurrence(s))")
local _, dup2 = conv:gsub("I'll edit it%.", "")
check(dup2 == 1, "intermediate (model_call_id) text not duplicated (got " .. dup2 .. ")")
check(conv:find("30 out") ~= nil, "usage line rendered")

-- Tool / diff rendering.
check(conv:find("edited `[^`]*sample%.txt`") ~= nil, "edit tool rendered with file")
check(conv:find("pending") ~= nil, "change marked pending in panel")
check(conv:find("```diff") ~= nil, "diff fence rendered")
check(conv:find("%+goodbye world") ~= nil, "added line shown in diff")
check(conv:find("%-hello world") ~= nil, "removed line shown in diff")
check(conv:find("⚙ read") ~= nil, "read tool note rendered")

-- 3. Prompt buffer cleared after submit.
local prompt_after = table.concat(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), "\n")
check(vim.trim(prompt_after) == "", "prompt cleared after submit")

-- 4. Mode toggle.
ui.toggle_mode()
neocursor.open()

-- 5. Selection context build.
local context = require("neocursor.context")
local tmpbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, { "line a", "line b", "line c" })
local sel = context.selection_from_range(tmpbuf, 1, 2)
check(sel ~= nil and #sel.lines == 2, "selection_from_range captures lines")
local built = context.build("explain", {}, sel)
check(built.prompt:find("line a") ~= nil and built.prompt:find("explain") ~= nil, "context.build embeds selection + question")
check(built.label ~= nil and built.label:find(":1%-2") ~= nil, "context label has line range")

-- 6. diff module helpers.
local diff = require("neocursor.diff")
local name, payload = diff.parse_tool({
  type = "tool_call",
  subtype = "completed",
  tool_call = {
    -- sibling bookkeeping keys must be ignored
    toolCallId = "t2",
    hookAdditionalContexts = {},
    startedAtMs = "1",
    completedAtMs = "2",
    editToolCall = { args = { path = "/tmp/x.txt" }, result = { success = {
      diffString = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b",
      linesAdded = 1, linesRemoved = 1, path = "/tmp/x.txt",
      beforeFullFileContent = "a\n", afterFullFileContent = "b\n",
    } } },
  },
})
check(name == "editToolCall", "parse_tool extracts tool name (ignores siblings)")
local change = diff.change_from_payload(name, payload)
check(change ~= nil and change.added == 1 and change.removed == 1, "change_from_payload extracts counts")
local hunks = diff.diff_hunks(change.diff)
local hunktext = table.concat(hunks, "\n")
check(hunktext:find("^@@") ~= nil and hunktext:find("%-%-%- ") == nil, "diff_hunks strips file headers")

-- read tool should NOT be treated as a change.
local rname, rpayload = diff.parse_tool({
  tool_call = { readToolCall = { args = { path = "/tmp/x.txt" }, result = { success = { content = "x" } } } },
})
check(diff.change_from_payload(rname, rpayload) == nil, "read tool is not a change")

-- 7. Model list parsing via the fake binary.
local agent = require("neocursor.agent")
local models, mcode
agent.list_models(function(m, c) models, mcode = m, c end)
vim.wait(3000, function() return models ~= nil end, 20)
check(mcode == 0 and models ~= nil and #models == 4, "list_models parsed 4 models")
check(models[1].id == "auto" and models[1].current == true, "auto marked current, suffix stripped")
local has_opus = false
for _, m in ipairs(models or {}) do
  if m.id == "claude-opus-4-8-thinking-high" then has_opus = true end
end
check(has_opus, "model id parsed correctly")

-- 8. Accept / reject review.
local scratch = cwd .. "/tests/scratch"
vim.fn.mkdir(scratch, "p")
local review_file = scratch .. "/review.txt"
local wf = io.open(review_file, "w")
wf:write("goodbye world\n")
wf:close()

local review_change = {
  id = 99,
  status = "pending",
  path = review_file,
  rel = "tests/scratch/review.txt",
  before = "hello world\n",
  after = "goodbye world\n",
  added = 1,
  removed = 1,
}
check(#diff.pending({ review_change }) == 1, "pending() finds pending change")

local ok_reject = diff.reject(review_change)
check(ok_reject == true and review_change.status == "rejected", "reject marks change rejected")
local rf = io.open(review_file, "r")
local restored = rf:read("*a")
rf:close()
check(restored == "hello world\n", "reject restores before content on disk")

local accept_change = vim.deepcopy(review_change)
accept_change.status = "pending"
local wf2 = io.open(review_file, "w")
wf2:write("goodbye world\n")
wf2:close()
check(diff.accept(accept_change) == true and accept_change.status == "accepted", "accept marks change accepted")
local af = io.open(review_file, "r")
local kept = af:read("*a")
af:close()
check(kept == "goodbye world\n", "accept leaves agent edit on disk")

-- 9. Session registry + transcript persistence.
local sessions = require("neocursor.sessions")
vim.wait(3000, function()
  return sessions.get("test-sess-1") ~= nil
end, 25)
local rec = sessions.get("test-sess-1")
check(rec ~= nil, "session recorded in registry after turn")
check(rec and rec.title == "hi", "session title derived from first prompt")
check(rec and rec.cwd == cwd, "session cwd recorded")
local transcript = sessions.load_transcript("test-sess-1")
check(transcript ~= nil and table.concat(transcript, "\n"):find("## You") ~= nil,
  "transcript saved with conversation content")
local listed = sessions.list(cwd)
check(#listed >= 1 and listed[1].id == "test-sess-1", "sessions.list returns the session for cwd")

-- 10. Discovery of CLI-created sessions (md5 hash dir + meta.json).
local md5out = vim.fn.system({ "md5sum" }, cwd)
local hash = md5out:match("%x+")
if hash and #hash == 32 then
  local extdir = cwd .. "/tests/scratch/chats/" .. hash .. "/ext-sess-1"
  vim.fn.mkdir(extdir, "p")
  local mf = io.open(extdir .. "/meta.json", "w")
  mf:write('{"schemaVersion":1,"createdAtMs":1700000000000,"hasConversation":true,"updatedAtMs":1700000001000}')
  mf:close()
  local all = sessions.list(cwd)
  local found_ext = false
  for _, s in ipairs(all) do
    if s.id == "ext-sess-1" and s.external then
      found_ext = true
    end
  end
  check(found_ext, "external CLI session discovered from chats dir")
else
  print("SKIP: md5sum unavailable, discovery not tested")
end

-- 11. Multiple panels at once, each with independent state.
local p2 = ui.open_new_panel()
check(ui.panel_count() == 2, "second panel opened (2 panels)")
check(ui.is_open(), "both panels visible")
vim.api.nvim_buf_set_lines(p2.prompt_buf, 0, -1, false, { "hello again" })
vim.api.nvim_set_current_win(p2.prompt_win)
ui.submit()
local done2 = vim.wait(5000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(p2.conv_buf, 0, -1, false), "\n")
  return text:find("Done, changed hello to goodbye%.") ~= nil
end, 25)
check(done2, "second panel streams its own response")
local conv2 = table.concat(vim.api.nvim_buf_get_lines(p2.conv_buf, 0, -1, false), "\n")
check(conv2:find("hello again") ~= nil, "second panel rendered its own prompt")
local conv1_after = table.concat(vim.api.nvim_buf_get_lines(conv_buf, 0, -1, false), "\n")
check(conv1_after:find("hello again") == nil, "first panel conversation untouched by second panel")

-- 12. Resume: transcript restored, session id set for --resume.
sessions.save_transcript("resume-42", { "## You", "", "old question", "", "old answer" })
sessions.record({ id = "resume-42", title = "older session", cwd = cwd, mode = "ask" })
local p3 = ui.resume({ id = "resume-42", title = "older session", mode = "ask" })
check(p3 ~= nil and p3.session_id == "resume-42", "resume sets the session id")
local conv3 = table.concat(vim.api.nvim_buf_get_lines(p3.conv_buf, 0, -1, false), "\n")
check(conv3:find("old question") ~= nil, "resume restores the saved transcript")
check(conv3:find("resumed session") ~= nil, "resume note rendered")

-- Resuming a session with no transcript still works (external session).
local p4 = ui.resume({ id = "ext-sess-1" }, { new_panel = true })
check(p4 ~= nil and p4.session_id == "ext-sess-1", "resume of external session sets id")
local conv4 = table.concat(vim.api.nvim_buf_get_lines(p4.conv_buf, 0, -1, false), "\n")
check(conv4:find("No local transcript") ~= nil, "external resume shows no-transcript note")

-- resume_last picks the most recently updated session for this cwd.
neocursor.close()
check(not ui.is_open(), "all panels close cleanly")
local p5 = ui.resume_last(nil, {})
check(p5 ~= nil and p5.session_id ~= nil, "resume_last resumes a session")

-- 13. Close.
neocursor.close()
check(not ui.is_open(), "panel closes cleanly")

if #failures > 0 then
  print("\n" .. #failures .. " FAILURE(S)")
  vim.cmd("cquit 1")
else
  print("\nALL SMOKE TESTS PASSED")
  vim.cmd("qa! ")
end
