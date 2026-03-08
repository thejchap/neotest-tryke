# neotest-tryke

A [neotest](https://github.com/nvim-neotest/neotest) adapter for the [tryke](https://github.com/justinchapman/tryke) test framework.

## Requirements

- Neovim 0.9+
- [neotest](https://github.com/nvim-neotest/neotest)
- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) with the Python parser installed
- [tryke](https://github.com/justinchapman/tryke)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "nvim-neotest/neotest",
  dependencies = {
    "justinchapman/neotest-tryke",
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

## Configuration

All options are optional. Defaults are shown below.

```lua
require("neotest-tryke")({
  tryke_command = "tryke",   -- path to tryke binary
  mode = "direct",           -- "direct" (subprocess), "server" (persistent server), or "auto"
  args = {},                 -- extra CLI arguments passed to tryke
  workers = nil,             -- number of parallel workers (nil = tryke default)
  fail_fast = false,         -- stop on first failure
  server = {
    port = 2337,             -- tryke server port
    host = "127.0.0.1",      -- tryke server host
    auto_start = true,       -- start server automatically if not running
    auto_stop = true,        -- stop server on VimLeavePre
  },
})
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `tryke_command` | `string` | `"tryke"` | Path to the tryke binary |
| `mode` | `string` | `"direct"` | Execution mode: `"direct"`, `"server"`, or `"auto"` |
| `args` | `string[]` | `{}` | Extra CLI arguments passed to tryke |
| `workers` | `number\|nil` | `nil` | Number of parallel workers |
| `fail_fast` | `boolean` | `false` | Stop on first failure |
| `server.port` | `number` | `2337` | Server port |
| `server.host` | `string` | `"127.0.0.1"` | Server host |
| `server.auto_start` | `boolean` | `true` | Auto-start server if not running |
| `server.auto_stop` | `boolean` | `true` | Auto-stop server on exit |

## Usage

Run tests using neotest commands:

- `:Neotest run` — run the nearest test
- `:Neotest run file` — run the current file
- `:Neotest summary` — toggle the test summary panel
- `:Neotest output` — show test output

## Development

### Prerequisites

- [busted](https://lunarmodules.github.io/busted/) via [LuaRocks](https://luarocks.org/): `luarocks --lua-version 5.1 install busted`
- [lua-language-server](https://github.com/LuaLS/lua-language-server)

### Run tests

```sh
make test
```

### Run static analysis

```sh
make check
```
