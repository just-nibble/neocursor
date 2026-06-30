-- neocursor: gathers editor context (current file, line, or visual selection)
-- to attach to a prompt.
local config = require("neocursor.config")

local M = {}

local function relpath(name)
  if not name or name == "" then
    return nil
  end
  local rel = vim.fn.fnamemodify(name, ":.")
  return rel ~= "" and rel or name
end

-- Inspect the current tab and return the first "real" editing window/buffer
-- that is not one of the neocursor panel buffers.
-- exclude: a set-like table of buffer numbers to skip.
function M.current_origin(exclude)
  exclude = exclude or {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not exclude[buf] and vim.api.nvim_buf_is_valid(buf) then
      local bt = vim.bo[buf].buftype
      if bt == "" then
        local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
        return {
          win = win,
          buf = buf,
          name = relpath(vim.api.nvim_buf_get_name(buf)),
          filetype = vim.bo[buf].filetype,
          cursor = ok and cursor[1] or 1,
        }
      end
    end
  end
  return {}
end

-- Build a selection table from an explicit line range in a buffer.
function M.selection_from_range(buf, l1, l2)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  l1 = math.max(l1 or 1, 1)
  l2 = math.max(l2 or l1, l1)
  local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  local cap = config.options.context.max_selection_lines
  local truncated = false
  if #lines > cap then
    local sliced = {}
    for i = 1, cap do
      sliced[i] = lines[i]
    end
    lines = sliced
    truncated = true
  end
  return {
    name = relpath(vim.api.nvim_buf_get_name(buf)),
    filetype = vim.bo[buf].filetype,
    l1 = l1,
    l2 = l2,
    lines = lines,
    truncated = truncated,
  }
end

-- Compose the final prompt string and a short context label for display.
-- question: the user's text.
-- origin:   table from current_origin() (may be empty).
-- selection: optional selection table (overrides origin file reference).
-- returns: { prompt = <string>, label = <string|nil> }
function M.build(question, origin, selection)
  local o = config.options
  local parts = {}
  local label = nil

  if selection and selection.lines and #selection.lines > 0 then
    local where = (selection.name or "buffer") .. ":" .. selection.l1 .. "-" .. selection.l2
    label = where
    local fence = selection.filetype and selection.filetype ~= "" and selection.filetype or ""
    table.insert(parts, "The user is asking about this code from `" .. where .. "`:")
    table.insert(parts, "```" .. fence)
    vim.list_extend(parts, selection.lines)
    table.insert(parts, "```")
    if selection.truncated then
      table.insert(parts, "(selection truncated)")
    end
    table.insert(parts, "")
  elseif o.context.include_file and origin and origin.name then
    label = origin.name
    table.insert(parts, string.format(
      "The user is editing `%s` (filetype: %s, cursor on line %d). Open it if you need its contents.",
      origin.name, origin.filetype ~= "" and origin.filetype or "none", origin.cursor or 1
    ))
    table.insert(parts, "")
  end

  table.insert(parts, question)

  return {
    prompt = table.concat(parts, "\n"),
    label = label,
  }
end

return M
