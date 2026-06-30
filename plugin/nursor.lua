-- nursor: command and autoload registration. Loaded automatically by Neovim.
if vim.g.loaded_nursor then
  return
end
vim.g.loaded_nursor = true

if vim.fn.has("nvim-0.7") == 0 then
  vim.notify("nursor requires Neovim 0.7+", vim.log.levels.ERROR)
  return
end

local function nursor()
  return require("nursor")
end

local cmd = vim.api.nvim_create_user_command

cmd("Nursor", function()
  nursor().toggle()
end, { desc = "Toggle the nursor agent panel" })

cmd("NursorOpen", function()
  nursor().open()
end, { desc = "Open the nursor agent panel" })

cmd("NursorClose", function()
  nursor().close()
end, { desc = "Close the nursor agent panel" })

cmd("NursorToggle", function()
  nursor().toggle()
end, { desc = "Toggle the nursor agent panel" })

cmd("NursorNew", function()
  nursor().open()
  nursor().new_chat()
end, { desc = "Start a new nursor chat" })

cmd("NursorMode", function()
  nursor().open()
  nursor().toggle_mode()
end, { desc = "Cycle the nursor agent mode" })

cmd("NursorModel", function()
  nursor().pick_model()
end, { desc = "Pick the nursor agent model" })

cmd("NursorDiff", function()
  nursor().show_changes()
end, { desc = "View agent file changes as a diff (read-only)" })

cmd("NursorReview", function()
  nursor().review_changes()
end, { desc = "Review a pending agent change (accept or reject)" })

cmd("NursorAccept", function()
  nursor().accept_changes()
end, { desc = "Accept a pending agent file change" })

cmd("NursorReject", function()
  nursor().reject_changes()
end, { desc = "Reject a pending agent file change (revert)" })

cmd("NursorStop", function()
  nursor().stop()
end, { desc = "Stop the in-flight nursor response" })

-- Range-aware: in visual mode (or with an explicit range) the selected lines
-- are attached as context. Any trailing text becomes the question and is sent
-- immediately; otherwise the panel just opens with the selection attached.
cmd("NursorAsk", function(opts)
  local question = (opts.args and opts.args ~= "") and opts.args or nil
  if opts.range and opts.range > 0 then
    nursor().ask_range(0, opts.line1, opts.line2, question)
  else
    nursor().ask(question)
  end
end, { nargs = "*", range = true, desc = "Ask nursor about the current line/selection" })
