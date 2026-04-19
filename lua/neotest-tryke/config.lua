local M = {}

local defaults = {
  tryke_command = "tryke",
  mode = "direct",
  -- "treesitter" (default): in-process TreeSitter-based discovery. Fastest
  -- for small/medium files and works without spawning subprocesses.
  -- "cli": delegate to `tryke test <file> --collect-only --reporter json`.
  -- Slower per-file (subprocess overhead) but always matches whatever the
  -- tryke CLI itself recognises — useful when new tryke discovery shapes
  -- land before the plugin's treesitter queries catch up.
  discovery = "treesitter",
  args = {},
  server = {
    port = 2337,
    host = "127.0.0.1",
    auto_start = true,
    auto_stop = true,
  },
  workers = nil,
  fail_fast = false,
}

function M.get(user_opts)
  return vim.tbl_deep_extend("force", defaults, user_opts or {})
end

return M
