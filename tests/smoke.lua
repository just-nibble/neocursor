-- Headless smoke test for nursor.
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

local nursor = require("nursor")
nursor.setup({
  cmd = cwd .. "/tests/fake-cursor-agent",
  default_mode = "ask",
})

local ui = require("nursor.ui")

-- 1. Open the panel.
nursor.open()
check(ui.is_open(), "panel opens (conversation + prompt windows)")

-- Find the panel buffers.
local conv_buf, prompt_buf
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "markdown" and vim.bo[b].buftype == "nofile" then
    local first = (vim.api.nvim_buf_get_lines(b, 0, 1, false))[1] or ""
    if first:match("^# nursor") then
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
nursor.open()

-- 5. Selection context build.
local context = require("nursor.context")
local tmpbuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(tmpbuf, 0, -1, false, { "line a", "line b", "line c" })
local sel = context.selection_from_range(tmpbuf, 1, 2)
check(sel ~= nil and #sel.lines == 2, "selection_from_range captures lines")
local built = context.build("explain", {}, sel)
check(built.prompt:find("line a") ~= nil and built.prompt:find("explain") ~= nil, "context.build embeds selection + question")
check(built.label ~= nil and built.label:find(":1%-2") ~= nil, "context label has line range")

-- 6. diff module helpers.
local diff = require("nursor.diff")
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
local agent = require("nursor.agent")
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

-- 9. Close.
nursor.close()
check(not ui.is_open(), "panel closes cleanly")

if #failures > 0 then
  print("\n" .. #failures .. " FAILURE(S)")
  vim.cmd("cquit 1")
else
  print("\nALL SMOKE TESTS PASSED")
  vim.cmd("qa! ")
end
