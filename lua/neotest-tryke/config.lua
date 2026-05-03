local M = {}

local defaults = {
  tryke_command = "tryke",
  -- Path to the Python interpreter used to spawn worker processes,
  -- forwarded as `--python <path>` to both `tryke test` and `tryke
  -- server`. Tryke removed its auto-`.venv/bin/python3` lookup, so
  -- without this the runner uses bare `python`/`python3` from PATH —
  -- which usually doesn't have the project's tryke package installed
  -- when neovim isn't launched from an activated venv. Point this at
  -- the workspace venv interpreter, or set `[tool.tryke] python`
  -- in pyproject.toml so neither neotest nor your shell needs to
  -- think about it.
  python = nil,
  mode = "direct",
  -- "treesitter" (default): in-process TreeSitter-based discovery. Fastest
  -- for small/medium files and works without spawning subprocesses.
  -- "cli": delegate to `tryke test <file> --collect-only --reporter json`.
  -- Slower per-file (subprocess overhead) but always matches whatever the
  -- tryke CLI itself recognises — useful when new tryke discovery shapes
  -- land before the plugin's treesitter queries catch up.
  discovery = "treesitter",
  -- Verbosity of `stdpath("log")/neotest-tryke.log`. Accepts a string
  -- ("trace" | "debug" | "info" | "warn" | "error") or a numeric
  -- `vim.log.levels` value. Crank to "debug" to see the exact command
  -- line invoked per run, or to "trace" to see every JSON event streamed
  -- back from tryke — useful when tests are "failing" for reasons that
  -- aren't assertion failures (id mismatch, missing binary, etc.).
  log_level = "info",
  -- Verbosity passed to the spawned `tryke` process via `TRYKE_LOG`.
  -- Lights up both rust runtime logs and python worker logs on stderr,
  -- which the strategy surfaces in neotest's output panel. `nil` leaves
  -- TRYKE_LOG unset so tryke uses its own default (`warn` on rust,
  -- silent on workers) — the right answer for normal runs. Crank to
  -- "info" or "debug" when diagnosing a flaky worker.
  tryke_log_level = nil,
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
