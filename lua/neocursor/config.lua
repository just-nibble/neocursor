-- neocursor: configuration defaults and merge logic.
local M = {}

M.defaults = {
  -- Path to (or name of) the cursor-agent binary.
  cmd = "cursor-agent",

  -- Model to use. nil/"" => let cursor-agent pick (Auto). e.g. "sonnet-4.5".
  model = nil,

  -- Default capability when a panel is opened: "ask" (read-only Q&A) or "agent".
  default_mode = "ask",

  -- Modes the <M-t> toggle cycles through, in order (inside the panel).
  mode_cycle = { "ask", "agent" },

  -- Pass --trust so the workspace is trusted in headless mode (no prompt).
  trust = true,

  -- In "agent" mode, pass --force so tool calls run without interactive prompts.
  -- Headless agent mode cannot answer permission prompts, so this is required
  -- for the agent to actually edit files / run commands. Set false to keep it
  -- effectively read-only even in agent mode.
  agent_force = true,

  context = {
    -- When no visual selection is given, tell the agent which file/line the
    -- cursor is on so it can open the file itself.
    include_file = true,
    -- Hard cap on selection lines embedded into the prompt.
    max_selection_lines = 600,
  },

  sessions = {
    -- Where neocursor stores its session registry and transcripts.
    -- nil => stdpath("data") .. "/neocursor".
    dir = nil,
    -- Where the cursor-agent CLI stores its chats (for discovering sessions
    -- started outside Neovim). nil => ~/.cursor/chats.
    chats_dir = nil,
    -- Maximum number of sessions shown in the picker.
    max = 50,
  },

  ui = {
    -- Sidebar width. <= 1 is treated as a fraction of total columns,
    -- > 1 is an absolute column count.
    width = 0.40,
    -- Height (in rows) of the prompt input area at the bottom.
    prompt_height = 6,
    -- "right" or "left".
    position = "right",
    wrap = true,
    -- Show token usage / duration after each answer.
    show_usage = true,
    -- Render the model's "thinking" content (if any).
    show_thinking = false,
    -- Spinner frames shown in the winbar while the agent is responding.
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  },

  -- Buffer-local keymaps inside the panel. Set any to false/nil to disable.
  keymaps = {
    submit = "<C-s>",        -- submit prompt (insert + normal mode)
    submit_normal = "<CR>",  -- submit prompt (normal mode only)
    new_chat = "<C-n>",      -- start a fresh chat (clears session)
    toggle_mode = "<M-t>",   -- Alt+t: cycle mode (avoid <C-t> — Vim tag pop / E73)
    model = "<C-g>",         -- open the model picker
    review = "<C-y>",        -- review a pending change (side-by-side + accept/reject)
    accept = "<C-a>",        -- accept a pending change (keep agent edit)
    reject = "<C-x>",        -- reject a pending change (revert file)
    diff = "<C-y>",          -- alias for review (deprecated name)
    focus_prompt = "i",      -- from the conversation window, jump to prompt
    close = "q",             -- close the panel (from either window, normal mode)
    stop = "<C-c>",          -- stop an in-flight response
    sessions = "<M-s>",      -- Alt+s: pick a session to view/resume
    new_panel = "<M-n>",     -- Alt+n: open an additional panel (parallel session)
  },

  -- Optional GLOBAL keymaps. Only applied when require("neocursor").setup{} is
  -- called. Each maps to a command; set to false/nil to skip.
  global_keymaps = {
    toggle = nil,            -- e.g. "<leader>cc" — opens/closes panel from any buffer
    ask = nil,               -- e.g. "<leader>ca" (works in normal + visual)
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
