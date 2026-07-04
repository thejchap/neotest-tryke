# neotest-tryke

A [neotest](https://github.com/nvim-neotest/neotest) adapter for the [tryke](https://github.com/thejchap/tryke) test framework.


<img alt="Screenshot 2026-07-04 at 15 49 39" src="https://github.com/user-attachments/assets/d12983aa-998b-492e-b976-5ac25844ace6" />


## requirements

- Neovim 0.9+
- [neotest](https://github.com/nvim-neotest/neotest)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with the python parser installed
- [tryke](https://github.com/thejchap/tryke)

## installation

using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    "thejchap/neotest-tryke",
  },
  config = function()
    require("neotest").setup({
      adapters = {
        require("neotest-tryke")({
          -- options (see Configuration below)
        }),
      },
    })
  end,
}
```

## configuration

all options are optional. Defaults are shown below.

```lua
require("neotest-tryke")({
  tryke_command = "tryke",   -- path to tryke binary
  python = nil,              -- path to python interpreter (`--python <path>`); nil = tryke default
  mode = "direct",           -- "direct" (subprocess) or "server" (persistent server)
  discovery = "treesitter",  -- "treesitter" (in-process) or "cli" (shell out to tryke)
  log_level = "info",        -- plugin log verbosity (this plugin's own logger)
  tryke_log_level = nil,     -- TRYKE_LOG forwarded to tryke (rust + python workers); nil = silent default
  args = {},                 -- extra CLI arguments passed to tryke
  workers = nil,             -- number of parallel workers (nil = tryke default)
  fail_fast = false,         -- stop on first failure
})
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `tryke_command` | `string` | `"tryke"` | Path to the tryke binary |
| `python` | `string\|nil` | `nil` | Path to the Python interpreter for spawned workers, forwarded as `--python <path>`. When unset, tryke uses bare `python`/`python3` from `PATH` — usually wrong unless your venv is active in the spawning environment. Point at the workspace venv or set `[tool.tryke] python` in `pyproject.toml`. |
| `mode` | `string` | `"direct"` | Execution mode: `"direct"` spawns a subprocess per run. `"server"` is EXPERIMENTAL - IDE communicates with Tryke over an LSP-style client/server connection. |
| `discovery` | `string` | `"treesitter"` | Test discovery backend: `"treesitter"` (in-process, fast) or `"cli"` (delegate to `tryke test --collect-only`) |
| `log_level` | `string\|number` | `"info"` | Plugin log verbosity (this plugin's own log file). String or numeric `vim.log.levels`. Logs go to `stdpath("log")/neotest-tryke.log`. |
| `tryke_log_level` | `string\|nil` | `nil` | Set `TRYKE_LOG=<level>` on the spawned tryke process to surface rust runtime logs **and** python worker logs in neotest's output panel. Crank to `"info"` or `"debug"` when diagnosing a flaky worker; leave unset for normal runs. |
| `args` | `string[]` | `{}` | Extra CLI arguments passed to tryke |
| `workers` | `number\|nil` | `nil` | Number of parallel workers |
| `fail_fast` | `boolean` | `false` | Stop on first failure |

### server mode

EXPERIMENTAL - IDE communicates with Tryke over an LSP-style client/server connection.

In `mode = "server"` the plugin spawns `tryke server` once per nvim session and talks newline-delimited JSON-RPC over the child process's stdin/stdout. There is no TCP endpoint anymore — tryke removed the `--port` flag and its listener — so there's nothing to configure: the plugin owns the server's lifecycle end to end. The process is reused across runs (that's where the warm-worker speedup comes from) and shut down on nvim exit by closing its stdin, which the server treats as its EOF shutdown signal. Because the transport is the spawned process itself, attaching to an externally started server is no longer possible; the old `server.host` / `server.port` / `server.auto_start` / `server.auto_stop` options are gone and are ignored if passed.

### logging

All plugin activity is written to a dedicated file at `stdpath("log")/neotest-tryke.log` (typically `~/.local/state/nvim/log/neotest-tryke.log`). Set `log_level` to crank verbosity without touching the shared `neotest.log`:

- `"info"` (default) — lifecycle only: setup, build_spec, server up/down, run complete.
- `"debug"` — adds exact command line, cwd, results path, id counts, unmatched-id warnings.
- `"trace"` — adds every streamed JSON event and each discovered test with its groups/case_label.

Tail it while diagnosing a failing run:

```sh
tail -F ~/.local/state/nvim/log/neotest-tryke.log
```

If neotest says "the test run did not record any output" or every test is getting reported as failed/skipped, `log_level = "trace"` is the fastest path to seeing whether it's an id-format drift, a tryke binary issue, or a wedged server process.

### discovery mode

`discovery = "treesitter"` (default) parses each file in-process with the same TreeSitter queries the plugin ships. Fastest path and has no subprocess cost.

`discovery = "cli"` delegates each file to `tryke test <path> --collect-only --reporter json` and builds the position tree from its JSON output. Slower per file (subprocess overhead) but always matches whatever the tryke CLI itself recognises — useful when a new tryke discovery shape lands before the plugin's queries catch up, or when you'd rather have one source of truth. If the CLI call fails the plugin logs the error and falls back to TreeSitter for that file, so a missing/broken binary doesn't take down discovery entirely.

## conflict with neotest-python

if you have [neotest-python](https://github.com/nvim-neotest/neotest-python) installed, both adapters will claim Python test files and may interfere with each other. To avoid this, disable neotest-python by removing it from your adapters list:

```lua
require("neotest").setup({
  adapters = {
    -- remove or comment out neotest-python:
    -- require("neotest-python"),

    require("neotest-tryke")(),
  },
})
```

if you need neotest-python for non-tryke projects, you can conditionally load adapters per project using [lazy.nvim](https://github.com/folke/lazy.nvim) `cond` or by checking for a `tryke.toml` in your neotest config.

## usage

Run tests using neotest commands:

- `:Neotest run` — run the nearest test
- `:Neotest run file` — run the current file
- `:Neotest summary` — toggle the test summary panel
- `:Neotest output` — show test output

## development

### prerequisites

- [busted](https://lunarmodules.github.io/busted/) via [LuaRocks](https://luarocks.org/): `luarocks --lua-version 5.1 install busted`
- [lua-language-server](https://github.com/LuaLS/lua-language-server)

### tests

```sh
make test
```

### static analysis

```sh
make check
```
