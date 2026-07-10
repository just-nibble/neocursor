-- neocursor: avante-style inline diff.
--
-- Renders an agent file change directly inside the file's own buffer with
-- colour highlights: added/changed lines are highlighted green in place, and
-- the removed lines are shown as red virtual lines above them. Each hunk can be
-- accepted (keep the agent's version) or rejected (restore the original) right
-- in the buffer, without leaving for a side-by-side diff tab.
local config = require("neocursor.config")

local M = {}

local ns = vim.api.nvim_create_namespace("neocursor_inline_diff")

-- Per-buffer review state so the buffer-local keymaps can find their hunks.
M._states = {}

----------------------------------------------------------------------
-- pure helpers (no side effects — used by the smoke test)
----------------------------------------------------------------------

-- Split file content into buffer lines, dropping the empty element produced by
-- a trailing newline so the buffer isn't given a spurious blank last line.
local function to_lines(s)
  local lines = vim.split(s or "", "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

-- Join buffer lines back into file content (with a trailing newline).
local function to_content(lines)
  if #lines == 0 then
    return ""
  end
  return table.concat(lines, "\n") .. "\n"
end

-- vim.diff hunk indices → normalized { start_a, count_a, start_b, count_b }.
function M.compute_hunks(before, after)
  local raw = vim.diff(before or "", after or "", {
    result_type = "indices",
    algorithm = "histogram",
  })
  local out = {}
  for _, h in ipairs(raw or {}) do
    table.insert(out, { start_a = h[1], count_a = h[2], start_b = h[3], count_b = h[4] })
  end
  return out
end

-- Break the file into an ordered list of blocks:
--   { kind = "common", lines = {...} }
--   { kind = "hunk", before = {...}, after = {...}, decision = "pending" }
-- Reconstructing the buffer from these blocks (see render_content) yields the
-- "after" file when every hunk is pending/accepted and the "before" file when
-- every hunk is rejected.
function M.build_blocks(before, after)
  local a = to_lines(before)
  local b = to_lines(after)
  local hunks = M.compute_hunks(before, after)

  local blocks = {}
  local ai, bi = 1, 1

  for _, h in ipairs(hunks) do
    local a_first, a_last, b_first, b_last
    if h.count_a > 0 then
      a_first, a_last = h.start_a, h.start_a + h.count_a - 1
    else
      a_first, a_last = h.start_a + 1, h.start_a -- empty range
    end
    if h.count_b > 0 then
      b_first, b_last = h.start_b, h.start_b + h.count_b - 1
    else
      b_first, b_last = h.start_b + 1, h.start_b -- empty range
    end

    local common = {}
    for i = bi, b_first - 1 do
      table.insert(common, b[i])
    end
    if #common > 0 then
      table.insert(blocks, { kind = "common", lines = common })
    end

    local before_h, after_h = {}, {}
    for i = a_first, a_last do
      table.insert(before_h, a[i])
    end
    for i = b_first, b_last do
      table.insert(after_h, b[i])
    end
    table.insert(blocks, { kind = "hunk", before = before_h, after = after_h, decision = "pending" })

    ai = a_last + 1
    bi = b_last + 1
  end

  local tail = {}
  for i = bi, #b do
    table.insert(tail, b[i])
  end
  if #tail > 0 then
    table.insert(blocks, { kind = "common", lines = tail })
  end

  return blocks
end

-- Materialize the buffer lines for the current set of decisions. Rejected
-- hunks contribute their "before" lines, everything else the "after" lines.
function M.render_content(blocks)
  local out = {}
  for _, blk in ipairs(blocks) do
    if blk.kind == "common" then
      vim.list_extend(out, blk.lines)
    elseif blk.decision == "reject" then
      vim.list_extend(out, blk.before)
    else
      vim.list_extend(out, blk.after)
    end
  end
  return out
end

----------------------------------------------------------------------
-- highlights
----------------------------------------------------------------------

-- Define the highlight groups (linked to the built-in diff groups by default,
-- so colours work out of the box and respect the user's colorscheme).
local function ensure_highlights()
  local hl = config.options.inline_diff.highlights
  local function link(name, target)
    if vim.fn.hlexists(name) == 0 then
      pcall(vim.api.nvim_set_hl, 0, name, { link = target, default = true })
    end
  end
  link(hl.add, "DiffAdd")
  link(hl.delete, "DiffDelete")
end

----------------------------------------------------------------------
-- rendering into a live buffer
----------------------------------------------------------------------

local function pending_count(blocks)
  local n = 0
  for _, blk in ipairs(blocks) do
    if blk.kind == "hunk" and blk.decision == "pending" then
      n = n + 1
    end
  end
  return n
end

-- Write the current merged content into the buffer and lay down the overlay
-- extmarks for every still-pending hunk. Returns the anchor rows (0-based) of
-- the pending hunks, in order, for navigation.
local function render(st)
  local buf = st.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end
  local hl = config.options.inline_diff.highlights

  local lines = M.render_content(st.blocks)
  local was_mod = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = was_mod

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local row = 0
  local anchors = {}
  for _, blk in ipairs(st.blocks) do
    if blk.kind == "common" then
      row = row + #blk.lines
    elseif blk.decision == "reject" then
      row = row + #blk.before
    else
      -- pending or accepted: buffer shows the "after" lines.
      local n = #blk.after
      if blk.decision == "pending" then
        table.insert(anchors, row)
        -- Green highlight over the added/changed lines.
        for r = row, row + n - 1 do
          vim.api.nvim_buf_set_extmark(buf, ns, r, 0, {
            line_hl_group = hl.add,
            hl_eol = true,
          })
        end
        -- Red virtual lines for the removed original.
        if #blk.before > 0 then
          local virt = {}
          for _, l in ipairs(blk.before) do
            table.insert(virt, { { l == "" and " " or l, hl.delete } })
          end
          if n > 0 then
            vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
              virt_lines = virt,
              virt_lines_above = true,
            })
          else
            -- Pure deletion: nothing to highlight, attach the removed lines
            -- above the following line (or below the last line at EOF).
            local last = math.max(0, #lines - 1)
            if row <= last then
              vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                virt_lines = virt,
                virt_lines_above = true,
              })
            else
              vim.api.nvim_buf_set_extmark(buf, ns, last, 0, {
                virt_lines = virt,
                virt_lines_above = false,
              })
            end
          end
        end
      end
      row = row + n
    end
  end

  st.anchors = anchors
  return anchors
end

local function persist(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local content = to_content(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false))
  local f = io.open(st.change.path, "w")
  if f then
    f:write(content)
    f:close()
  end
  vim.bo[st.buf].modified = false
end

----------------------------------------------------------------------
-- window / buffer wiring
----------------------------------------------------------------------

-- Focus a normal (file) window, avoiding neocursor's own panels and floats,
-- then edit the target file there.
local function open_file(path)
  local target
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(w)
    if cfg.relative == nil or cfg.relative == "" then
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].buftype == "" then
        target = w
        break
      end
    end
  end
  if target then
    vim.api.nvim_set_current_win(target)
  else
    vim.cmd(config.options.ui.position == "left" and "botright vsplit" or "topleft vsplit")
  end
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

local function set_winbar(st)
  if not (st.win and vim.api.nvim_win_is_valid(st.win)) then
    return
  end
  local k = config.options.inline_diff.keymaps
  local remaining = pending_count(st.blocks)
  vim.wo[st.win].winbar = string.format(
    "%%#Title#  neocursor inline diff%%* · %s · %d left · %s accept · %s reject · %s/%s all · %s/%s nav · %s finish",
    st.change.rel,
    remaining,
    k.accept, k.reject, k.accept_all, k.reject_all, k.next, k.prev, k.quit
  )
end

-- Hunk (block index) whose displayed region is at or after the cursor line.
local function current_hunk(st)
  if not (st.win and vim.api.nvim_win_is_valid(st.win)) then
    return nil
  end
  local cur = vim.api.nvim_win_get_cursor(st.win)[1] - 1 -- 0-based
  local row = 0
  local first_pending
  for i, blk in ipairs(st.blocks) do
    local n
    if blk.kind == "common" then
      n = #blk.lines
    elseif blk.decision == "reject" then
      n = #blk.before
    else
      n = #blk.after
    end
    if blk.kind == "hunk" and blk.decision == "pending" then
      -- pending hunks always display their "after" region starting at row.
      if row + math.max(n, 1) > cur then
        return i
      end
      first_pending = first_pending or i
    end
    row = row + n
  end
  -- Cursor is past the last pending hunk: fall back to the first one.
  return first_pending
end

local function cleanup(st)
  if vim.api.nvim_buf_is_valid(st.buf) then
    vim.api.nvim_buf_clear_namespace(st.buf, ns, 0, -1)
    local k = config.options.inline_diff.keymaps
    for _, lhs in ipairs({ k.accept, k.reject, k.accept_all, k.reject_all, k.next, k.prev, k.quit }) do
      if lhs and lhs ~= "" then
        pcall(vim.keymap.del, "n", lhs, { buffer = st.buf })
      end
    end
  end
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    vim.wo[st.win].winbar = ""
  end
  if st.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, st.augroup)
  end
  M._states[st.buf] = nil
end

local function finalize(st)
  persist(st)
  local accepts, rejects = 0, 0
  for _, blk in ipairs(st.blocks) do
    if blk.kind == "hunk" then
      if blk.decision == "accept" then
        accepts = accepts + 1
      elseif blk.decision == "reject" then
        rejects = rejects + 1
      end
    end
  end
  cleanup(st)
  local o = st.opts
  if rejects == 0 then
    if o.on_accept then o.on_accept(st.change) end
  elseif accepts == 0 then
    if o.on_reject then o.on_reject(st.change) end
  else
    if o.on_partial then o.on_partial(st.change) end
  end
end

-- Re-render after a decision; finalize once nothing is pending. The buffer is
-- rebuilt from the decisions *before* persisting so disk always matches what
-- is shown.
local function after_decision(st)
  render(st)
  persist(st)
  if pending_count(st.blocks) == 0 then
    finalize(st)
    return
  end
  set_winbar(st)
end

local function goto_first_pending(st)
  local anchors = st.anchors or {}
  if anchors[1] and st.win and vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.api.nvim_win_set_cursor, st.win, { anchors[1] + 1, 0 })
  end
end

local function navigate(st, dir)
  local anchors = st.anchors or {}
  if #anchors == 0 or not (st.win and vim.api.nvim_win_is_valid(st.win)) then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(st.win)[1] - 1
  local target
  if dir > 0 then
    for _, r in ipairs(anchors) do
      if r > cur then target = r break end
    end
    target = target or anchors[1]
  else
    for i = #anchors, 1, -1 do
      if anchors[i] < cur then target = anchors[i] break end
    end
    target = target or anchors[#anchors]
  end
  pcall(vim.api.nvim_win_set_cursor, st.win, { target + 1, 0 })
end

local function apply_keymaps(st)
  local k = config.options.inline_diff.keymaps
  local function map(lhs, fn, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = st.buf, nowait = true, silent = true, desc = desc })
    end
  end

  map(k.accept, function()
    local i = current_hunk(st)
    if i then
      st.blocks[i].decision = "accept"
      after_decision(st)
    end
  end, "neocursor: accept hunk")

  map(k.reject, function()
    local i = current_hunk(st)
    if i then
      st.blocks[i].decision = "reject"
      after_decision(st)
    end
  end, "neocursor: reject hunk")

  map(k.accept_all, function()
    for _, blk in ipairs(st.blocks) do
      if blk.kind == "hunk" and blk.decision == "pending" then
        blk.decision = "accept"
      end
    end
    after_decision(st)
  end, "neocursor: accept all hunks")

  map(k.reject_all, function()
    for _, blk in ipairs(st.blocks) do
      if blk.kind == "hunk" and blk.decision == "pending" then
        blk.decision = "reject"
      end
    end
    after_decision(st)
  end, "neocursor: reject all hunks")

  map(k.next, function()
    navigate(st, 1)
  end, "neocursor: next hunk")
  map(k.prev, function()
    navigate(st, -1)
  end, "neocursor: previous hunk")
  map(k.quit, function()
    finalize(st)
  end, "neocursor: finish inline diff")
end

----------------------------------------------------------------------
-- entry point
----------------------------------------------------------------------

-- Open an inline diff for `change` (needs .path, .before, .after).
-- opts: { on_accept(change), on_reject(change), on_partial(change) }
function M.open(change, opts)
  if not change or not change.path then
    vim.notify("neocursor: nothing to show inline", vim.log.levels.INFO)
    return
  end
  if (change.before or "") == (change.after or "") then
    vim.notify("neocursor: no changes to show inline", vim.log.levels.INFO)
    return
  end

  ensure_highlights()

  local win, buf = open_file(change.path)

  -- Clear any previous inline-diff session on this buffer.
  if M._states[buf] then
    cleanup(M._states[buf])
  end

  local st = {
    buf = buf,
    win = win,
    change = change,
    opts = opts or {},
    blocks = M.build_blocks(change.before, change.after),
    anchors = {},
  }
  M._states[buf] = st

  if pending_count(st.blocks) == 0 then
    vim.notify("neocursor: no changes to show inline", vim.log.levels.INFO)
    M._states[buf] = nil
    return
  end

  render(st)
  set_winbar(st)
  apply_keymaps(st)

  -- Abandon the review if the buffer is wiped/unloaded.
  st.augroup = vim.api.nvim_create_augroup("NeocursorInlineDiff" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    group = st.augroup,
    buffer = buf,
    callback = function()
      if M._states[buf] then
        cleanup(M._states[buf])
      end
    end,
  })

  goto_first_pending(st)
  return st
end

return M
