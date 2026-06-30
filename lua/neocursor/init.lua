-- neocursor: public API. A Cursor-style agent chat panel for Neovim powered by
-- the cursor-agent CLI.
local config = require("neocursor.config")

local M = {}

-- Lazily require the UI so that merely `require("neocursor")` is cheap.
local function ui()
  return require("neocursor.ui")
end

-- Optional. Plugin works with defaults without calling setup().
function M.setup(opts)
  config.setup(opts)

  local gk = config.options.global_keymaps or {}
  if gk.toggle and gk.toggle ~= "" then
    vim.keymap.set("n", gk.toggle, function()
      M.toggle()
    end, { silent = true, desc = "neocursor: toggle panel" })
  end
  if gk.ask and gk.ask ~= "" then
    vim.keymap.set("n", gk.ask, function()
      M.open()
    end, { silent = true, desc = "neocursor: ask" })
    vim.keymap.set("x", gk.ask, function()
      -- Send the current visual selection.
      local l1 = vim.fn.line("v")
      local l2 = vim.fn.line(".")
      if l1 > l2 then
        l1, l2 = l2, l1
      end
      vim.cmd("normal! \27") -- leave visual mode
      M.ask_range(0, l1, l2, nil)
    end, { silent = true, desc = "neocursor: ask about selection" })
  end

  return config.options
end

function M.open()
  ui().open()
end

function M.close()
  ui().close()
end

function M.toggle()
  ui().toggle()
end

function M.new_chat()
  ui().new_chat()
end

function M.toggle_mode()
  ui().toggle_mode()
end

function M.pick_model()
  ui().pick_model()
end

function M.show_changes()
  ui().show_changes()
end

function M.review_changes()
  ui().review_changes()
end

function M.accept_changes()
  ui().accept_changes()
end

function M.reject_changes()
  ui().reject_changes()
end

function M.stop()
  ui().stop()
end

-- Ask about an explicit line range in a buffer.
-- buf 0 means current buffer. question may be nil (just attach context).
function M.ask_range(buf, l1, l2, question)
  local context = require("neocursor.context")
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local selection = context.selection_from_range(buf, l1, l2)
  ui().ask(selection, question)
end

-- Ask with no explicit selection (uses current file as context).
function M.ask(question)
  ui().ask(nil, question)
end

return M
