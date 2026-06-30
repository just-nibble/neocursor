# neocursor

A Cursor-style agent chat panel for **Neovim**, powered by the
[`cursor-agent`](https://cursor.com/cli) CLI.

Open a sidebar, ask questions about your code, and watch the answer stream in —
just like Cursor's chat, but inside Neovim. Ask about the whole file, the
current line, or a visual selection. Switch between read-only **ask** mode and a
full **agent** that can edit files and run commands.

![layout](https://placehold.co/640x360?text=neocursor)

## Features

- Sidebar chat panel: conversation on top, prompt input at the bottom.
- Live token streaming via `cursor-agent --output-format stream-json --stream-partial-output`.
- Ask about a **visual selection** or **current line** (`:NeocursorAsk`).
- Per-panel **session continuity** (follow-up questions reuse `--resume`).
- Toggle between **ask** (read-only) and **agent** (can edit) without leaving the panel.
- **Model picker** (`:NeocursorModel`) populated from `cursor-agent --list-models`.
- **View agent changes**: file edits are shown inline as unified-diff hunks. Review
  each change and **accept** (keep) or **reject** (revert to the pre-edit file).
  `:NeocursorReview` opens a side-by-side diff with `a` / `r` keymaps.
- Token-usage / duration readout after each answer.
- `:checkhealth neocursor`.

## Requirements

- Neovim **0.7+** (0.10+ recommended).
- `cursor-agent` installed and on your `PATH`, and signed in:

```bash
# install (see https://cursor.com/cli) then sign in:
cursor-agent login
```

## Install

### lazy.nvim

```lua
{
  "chadify/neocursor",          -- or a local dir: dir = "~/code/chadify-cursor"
  cmd = { "Neocursor", "NeocursorAsk", "NeocursorOpen", "NeocursorToggle", "NeocursorNew" },
  opts = {
    -- global_keymaps = { toggle = "<leader>cc", ask = "<leader>ca" },
  },
}
```

### Local checkout (no plugin manager)

```vim
set runtimepath+=~/code/chadify-cursor
```

Then optionally, in `init.lua`:

```lua
require("neocursor").setup({})
```

`setup()` is optional — the plugin works with defaults out of the box.

## Usage

| Command | Description |
| --- | --- |
| `:Neocursor` | Toggle the panel. |
| `:NeocursorOpen` / `:NeocursorClose` | Open / close the panel. |
| `:NeocursorNew` | Start a fresh chat (clears the session). |
| `:NeocursorAsk {question}` | Ask about the current line. In **visual mode**, ask about the selection. |
| `:NeocursorMode` | Cycle the agent mode (ask ⇄ agent). |
| `:NeocursorModel` | Pick the model (from `cursor-agent --list-models`). |
| `:NeocursorReview` | Review a pending change (side-by-side diff; `a` accept, `r` reject). |
| `:NeocursorAccept` | Accept a pending change (keep the agent edit). |
| `:NeocursorReject` | Reject a pending change (restore the file to before the edit). |
| `:NeocursorDiff` | View any change as a read-only side-by-side diff. |
| `:NeocursorStop` | Stop an in-flight response. |

Typical flow:

1. `:Neocursor` opens the sidebar with the cursor in the prompt box.
2. Type a question, press `<C-s>` to send. The answer streams in above.
3. Ask follow-ups — they continue the same session.
4. Select lines in a file, then `:NeocursorAsk how can I simplify this?`

### Panel keymaps (buffer-local)

| Key | Action |
| --- | --- |
| `<C-s>` | Send the prompt (insert or normal mode) |
| `<CR>` | Send the prompt (normal mode) |
| `<C-n>` | New chat |
| `<M-t>` | Toggle ask ⇄ agent (inside panel only) |
| `<C-g>` | Pick model |
| `<C-y>` | Review pending change (opens diff; `a` accept, `r` reject) |
| `<C-a>` | Accept pending change |
| `<C-x>` | Reject pending change (revert file) |
| `<C-c>` | Stop the current response |
| `q` | Close the panel |
| `i` | (in conversation window) jump to the prompt |

## Configuration

Defaults (pass overrides to `setup`):

```lua
require("neocursor").setup({
  cmd = "cursor-agent",        -- path/name of the binary
  model = nil,                 -- e.g. "sonnet-4.5"; nil => Auto
  default_mode = "ask",        -- "ask" | "agent"
  mode_cycle = { "ask", "agent" },
  trust = true,                -- pass --trust (no workspace-trust prompt)
  agent_force = true,          -- agent mode runs tools without prompts (--force)

  context = {
    include_file = true,       -- tell the agent which file/line you're on
    max_selection_lines = 600,
  },

  ui = {
    width = 0.40,              -- <=1 fraction of columns, >1 absolute
    prompt_height = 6,
    position = "right",        -- "right" | "left"
    wrap = true,
    show_usage = true,
    show_thinking = false,
  },

  keymaps = {                  -- buffer-local, inside the panel
    submit = "<C-s>",
    submit_normal = "<CR>",
    new_chat = "<C-n>",
    toggle_mode = "<M-t>",
    model = "<C-g>",
    review = "<C-y>",
    accept = "<C-a>",
    reject = "<C-x>",
    focus_prompt = "i",
    close = "q",
    stop = "<C-c>",
  },

  global_keymaps = {           -- only applied when setup() is called
    toggle = "<leader>cc",     -- open/close panel (do NOT use <C-t> — that's Vim tag pop)
    ask = "<leader>ca",        -- ask about line/selection (normal + visual)
  },
})
```

## Modes & safety

- **ask** (default): runs `cursor-agent --mode ask`. Read-only Q&A; never edits.
- **agent**: runs `cursor-agent --force`. Because the panel is headless it can't
  answer permission prompts, so `--force` lets the agent actually edit files and
  run shell commands. Set `agent_force = false` to keep it from acting, or just
  stay in **ask** mode.

## How it works

Each turn spawns `cursor-agent -p --output-format stream-json
--stream-partial-output` (plus `--mode ask` or `--force`, and `--resume
<session>` for follow-ups). neocursor parses the NDJSON event stream:

- `system/init` → captures the `session_id`.
- `assistant` text events with a `timestamp_ms` **and no** `model_call_id` are the
  streaming deltas → rendered live. (Consolidated messages carry `model_call_id`
  or neither, and are skipped to avoid duplication.)
- `tool_call` (subtype `completed`) → edit-like tools are rendered as inline diffs,
  tracked as **pending** until you accept or reject. Reject restores
  `beforeFullFileContent` to disk.
- `result` → finalizes the turn and records usage + session id.

## Tests

An offline smoke test drives the whole UI against a stubbed `cursor-agent`
(no network or auth needed):

```bash
nvim --headless -u NONE -i NONE -c "luafile tests/smoke.lua"
```

## License

MIT
