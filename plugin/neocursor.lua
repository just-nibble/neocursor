-- neocursor: command and autoload registration. Loaded automatically by Neovim.
if vim.g.loaded_neocursor then
  return
end
vim.g.loaded_neocursor = true

if vim.fn.has("nvim-0.7") == 0 then
  vim.notify("neocursor requires Neovim 0.7+", vim.log.levels.ERROR)
  return
end

local function neocursor()
  return require("neocursor")
end

local cmd = vim.api.nvim_create_user_command

cmd("Neocursor", function()
  neocursor().toggle()
end, { desc = "Toggle the neocursor agent panel" })

cmd("NeocursorOpen", function()
  neocursor().open()
end, { desc = "Open the neocursor agent panel" })

cmd("NeocursorClose", function()
  neocursor().close()
end, { desc = "Close the neocursor agent panel" })

cmd("NeocursorToggle", function()
  neocursor().toggle()
end, { desc = "Toggle the neocursor agent panel" })

cmd("NeocursorNew", function()
  neocursor().open()
  neocursor().new_chat()
end, { desc = "Start a new neocursor chat" })

cmd("NeocursorNewPanel", function()
  neocursor().new_panel()
end, { desc = "Open an additional neocursor panel (parallel session)" })

-- With !, the picked session opens in a new panel instead of reusing the
-- current one — handy for running several sessions at once.
cmd("NeocursorSessions", function(opts)
  neocursor().sessions({ new_panel = opts.bang })
end, { bang = true, desc = "Pick a previous session to view/resume" })

cmd("NeocursorResume", function(opts)
  local id = (opts.args and opts.args ~= "") and opts.args or nil
  neocursor().resume(id, { new_panel = opts.bang })
end, { nargs = "?", bang = true, desc = "Resume the latest (or a specific) neocursor session" })

cmd("NeocursorMode", function()
  neocursor().open()
  neocursor().toggle_mode()
end, { desc = "Cycle the neocursor agent mode" })

cmd("NeocursorModel", function()
  neocursor().pick_model()
end, { desc = "Pick the neocursor agent model" })

cmd("NeocursorDiff", function()
  neocursor().show_changes()
end, { desc = "View agent file changes as a diff (read-only)" })

cmd("NeocursorReview", function()
  neocursor().review_changes()
end, { desc = "Review a pending agent change (accept or reject)" })

cmd("NeocursorInlineDiff", function()
  neocursor().inline_diff()
end, { desc = "Review a pending agent change inline in the file (colour-highlighted)" })

cmd("NeocursorAccept", function()
  neocursor().accept_changes()
end, { desc = "Accept a pending agent file change" })

cmd("NeocursorReject", function()
  neocursor().reject_changes()
end, { desc = "Reject a pending agent file change (revert)" })

cmd("NeocursorStop", function()
  neocursor().stop()
end, { desc = "Stop the in-flight neocursor response" })

-- Range-aware: in visual mode (or with an explicit range) the selected lines
-- are attached as context. Any trailing text becomes the question and is sent
-- immediately; otherwise the panel just opens with the selection attached.
cmd("NeocursorAsk", function(opts)
  local question = (opts.args and opts.args ~= "") and opts.args or nil
  if opts.range and opts.range > 0 then
    neocursor().ask_range(0, opts.line1, opts.line2, question)
  else
    neocursor().ask(question)
  end
end, { nargs = "*", range = true, desc = "Ask neocursor about the current line/selection" })
