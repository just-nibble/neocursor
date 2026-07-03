-- neocursor: :checkhealth neocursor
local config = require("neocursor.config")

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local err = health.error or health.report_error

function M.check()
  start("neocursor")

  local v = vim.version and vim.version() or nil
  local vstr = v and string.format("%d.%d.%d", v.major, v.minor, v.patch) or "unknown"
  if vim.fn.has("nvim-0.7") == 1 then
    ok("Neovim " .. vstr)
  else
    err("Neovim 0.7+ is required (found " .. vstr .. ")")
  end

  local bin = config.options.cmd or "cursor-agent"
  local resolved = vim.fn.exepath(bin)
  if resolved ~= "" then
    ok("cursor-agent found: " .. resolved)
  else
    err("cursor-agent not found on PATH (configured cmd = '" .. bin .. "')", {
      "Install it from https://cursor.com/cli and ensure it is on your PATH,",
      "or set require('neocursor').setup({ cmd = '/full/path/to/cursor-agent' }).",
    })
  end

  if vim.json and vim.json.decode then
    ok("vim.json available")
  else
    err("vim.json.decode is required (Neovim 0.7+)")
  end

  -- Optional helpers for discovering sessions started outside Neovim.
  if vim.fn.executable("md5sum") == 1 or vim.fn.executable("md5") == 1 then
    ok("md5sum/md5 found: external cursor-agent sessions can be discovered")
  else
    warn("md5sum/md5 not found: only sessions started from Neovim will be listed")
  end
  if vim.fn.executable("sqlite3") == 1 then
    ok("sqlite3 found: titles of external sessions can be read")
  else
    warn("sqlite3 not found: external sessions will show as untitled")
  end

  local mode = config.options.default_mode
  if mode == "agent" and config.options.agent_force then
    warn("default_mode = 'agent' with agent_force = true: the agent can edit files and run commands without prompts.")
  else
    ok("default mode: " .. tostring(mode))
  end
end

return M
