-- neocursor: parsing cursor-agent tool_call events, presenting file changes,
-- and accept/reject review (revert to captured "before" on reject).
local M = {}

local _review_seq = 0

function M.relpath(p)
  if not p or p == "" then
    return "?"
  end
  local rel = vim.fn.fnamemodify(p, ":.")
  return rel ~= "" and rel or p
end

function M.parse_tool(obj)
  local tc = obj.tool_call
  if type(tc) ~= "table" then
    return nil
  end
  for k, v in pairs(tc) do
    if type(k) == "string" and k:match("ToolCall$") and type(v) == "table" then
      return k, v
    end
  end
  return nil
end

function M.short_name(name)
  return (name or "tool"):gsub("ToolCall$", "")
end

function M.change_from_payload(name, payload)
  local res = payload and payload.result
  local success = res and res.success
  if type(success) ~= "table" then
    return nil
  end
  if not (success.diffString or success.afterFullFileContent) then
    return nil
  end
  local path = success.path or (payload.args and payload.args.path)
  _review_seq = _review_seq + 1
  return {
    id = _review_seq,
    status = "pending",
    tool = M.short_name(name),
    path = path,
    rel = M.relpath(path),
    diff = success.diffString,
    before = success.beforeFullFileContent,
    after = success.afterFullFileContent,
    added = success.linesAdded,
    removed = success.linesRemoved,
  }
end

function M.tool_summary(name, payload)
  local short = M.short_name(name)
  local args = (payload and payload.args) or {}
  if args.path then
    return short .. " " .. M.relpath(args.path)
  end
  if args.command then
    return short .. ": " .. tostring(args.command)
  end
  if args.query then
    return short .. ": " .. tostring(args.query)
  end
  if args.target_file then
    return short .. " " .. M.relpath(args.target_file)
  end
  return short
end

function M.diff_hunks(diffstr)
  local out = {}
  for _, l in ipairs(vim.split(diffstr or "", "\n", { plain = true })) do
    if not (l:match("^%-%-%- ") or l:match("^%+%+%+ ")) then
      table.insert(out, l)
    end
  end
  return out
end

function M.status_icon(change)
  if change.status == "accepted" then
    return "✓"
  elseif change.status == "rejected" then
    return "✗"
  end
  return "⏳"
end

function M.status_label(change)
  if change.status == "accepted" then
    return "accepted"
  elseif change.status == "rejected" then
    return "rejected"
  end
  return "pending"
end

function M.pending(changes)
  local out = {}
  for _, c in ipairs(changes or {}) do
    if c.status == "pending" then
      table.insert(out, c)
    end
  end
  return out
end

function M.write_file(path, content)
  if not path or path == "" then
    return false, "no path"
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir ~= "" and dir ~= "." then
    vim.fn.mkdir(dir, "p")
  end
  local f = io.open(path, "w")
  if not f then
    return false, "could not open " .. path
  end
  f:write(content or "")
  f:close()
  return true
end

function M.reload_file(path)
  if not path or path == "" then
    return
  end
  local bufnr = vim.fn.bufnr(path)
  if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent! checktime")
      if vim.bo.modified then
        vim.cmd("silent! edit")
      else
        vim.cmd("silent! edit")
      end
    end)
  end
end

-- Reject: restore the captured pre-edit snapshot to disk.
function M.reject(change)
  if not change or not change.path then
    return false, "invalid change"
  end
  local ok, err = M.write_file(change.path, change.before or "")
  if not ok then
    return false, err
  end
  M.reload_file(change.path)
  change.status = "rejected"
  return true
end

-- Accept: keep the agent edit (already on disk); mark reviewed.
function M.accept(change)
  if not change then
    return false, "invalid change"
  end
  change.status = "accepted"
  return true
end

function M.show(change)
  if not change then
    return
  end

  vim.cmd("tabnew")
  if change.path and vim.fn.filereadable(change.path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(change.path))
  else
    local after = vim.split(change.after or "", "\n", { plain = true })
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, after)
    vim.bo[b].buftype = "nofile"
    pcall(vim.api.nvim_buf_set_name, b, "neocursor://after/" .. (change.rel or "file"))
  end
  vim.cmd("diffthis")
  local ft = vim.bo.filetype

  vim.cmd("leftabove vnew")
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(change.before or "", "\n", { plain = true }))
  vim.bo[b].modifiable = false
  if ft and ft ~= "" then
    vim.bo[b].filetype = ft
  end
  pcall(vim.api.nvim_buf_set_name, b, "neocursor://before/" .. (change.rel or "file"))
  vim.cmd("diffthis")
end

-- Side-by-side review with accept / reject keymaps in the diff tab.
-- opts: { on_accept(change), on_reject(change), on_close() }
function M.review(change, opts)
  if not change then
    return
  end
  opts = opts or {}

  M.show(change)
  local tab = vim.api.nvim_get_current_tabpage()
  local winbar = string.format(
    " neocursor review · %s · %s · a accept · r reject · q close",
    change.rel,
    M.status_label(change)
  )

  local function set_winbar()
    if not vim.api.nvim_tabpage_is_valid(tab) then
      return
    end
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      vim.wo[w].winbar = winbar
    end
  end
  set_winbar()

  local group = vim.api.nvim_create_augroup("NeocursorReview" .. change.id, { clear = true })

  local function cleanup()
    pcall(vim.api.nvim_del_augroup_by_id, group)
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local b = vim.api.nvim_win_get_buf(w)
      pcall(vim.keymap.del, "n", "a", { buffer = b })
      pcall(vim.keymap.del, "n", "r", { buffer = b })
      pcall(vim.keymap.del, "n", "q", { buffer = b })
    end
  end

  local function close_tab()
    cleanup()
    if vim.api.nvim_tabpage_is_valid(tab) and tab == vim.api.nvim_get_current_tabpage() then
      vim.cmd("tabclose")
    elseif vim.api.nvim_tabpage_is_valid(tab) then
      vim.cmd("tabclose " .. vim.api.nvim_tabpage_get_number(tab))
    end
    if opts.on_close then
      opts.on_close()
    end
  end

  local function do_accept()
    if opts.on_accept then
      opts.on_accept(change)
    end
    close_tab()
  end

  local function do_reject()
    if opts.on_reject then
      opts.on_reject(change)
    end
    close_tab()
  end

  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function(ev)
      if tonumber(ev.match) == vim.api.nvim_tabpage_get_number(tab) then
        cleanup()
        if opts.on_close then
          opts.on_close()
        end
      end
    end,
  })

  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local b = vim.api.nvim_win_get_buf(w)
    vim.keymap.set("n", "a", do_accept, { buffer = b, nowait = true, silent = true, desc = "neocursor: accept change" })
    vim.keymap.set("n", "r", do_reject, { buffer = b, nowait = true, silent = true, desc = "neocursor: reject change" })
    vim.keymap.set("n", "q", close_tab, { buffer = b, nowait = true, silent = true, desc = "neocursor: close review" })
  end
end

return M
