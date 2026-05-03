local server = require("neotest-tryke.server")

describe("server._build_spawn_options", function()
  -- `vim.uv.os_environ` is real on a live nvim, but in the busted/plenary
  -- test runner we want a deterministic parent env so the splice
  -- assertion is stable. Wrap each test in a stub.
  local function with_os_environ(env, fn)
    local original = vim.uv.os_environ
    vim.uv.os_environ = function()
      return env
    end
    local ok, err = pcall(fn)
    vim.uv.os_environ = original
    if not ok then
      error(err)
    end
  end

  it("emits `server --port <port>` for a default config", function()
    local cfg = { tryke_command = "tryke" }
    local args, env = server._build_spawn_options(cfg, 2337)
    assert.same({ "server", "--port", "2337" }, args)
    -- No log level → no env override → libuv inherits parent env.
    assert.is_nil(env)
  end)

  it("appends --python when config.python is set", function()
    -- Order matters: tryke parses positional args in order, so `--python`
    -- must come after the subcommand but before any positional paths.
    local cfg = { tryke_command = "tryke", python = "/repo/.venv/bin/python3" }
    local args = server._build_spawn_options(cfg, 2337)
    assert.same(
      { "server", "--port", "2337", "--python", "/repo/.venv/bin/python3" },
      args
    )
  end)

  it("splices parent env and appends TRYKE_LOG when tryke_log_level is set", function()
    with_os_environ({ PATH = "/usr/bin", HOME = "/home/u" }, function()
      local cfg = { tryke_command = "tryke", tryke_log_level = "info" }
      local _, env = server._build_spawn_options(cfg, 2337)
      assert.is_table(env)
      -- libuv expects an array of `K=V` strings, NOT a `{ KEY = VAL }` map.
      -- Sort before comparing — `pairs` ordering on the spliced parent env
      -- is undefined.
      table.sort(env)
      assert.same(
        { "HOME=/home/u", "PATH=/usr/bin", "TRYKE_LOG=info" },
        env
      )
    end)
  end)

  it("leaves env as nil when tryke_log_level is unset", function()
    -- A nil env means libuv inherits the parent's whole env, which is
    -- what we want for the silent-default case. An empty table would
    -- give the child *no* env (no PATH, no HOME) and break the spawn.
    with_os_environ({ PATH = "/usr/bin" }, function()
      local cfg = { tryke_command = "tryke" }
      local _, env = server._build_spawn_options(cfg, 2337)
      assert.is_nil(env)
    end)
  end)

  it("combines python and tryke_log_level", function()
    with_os_environ({ PATH = "/usr/bin" }, function()
      local cfg = {
        tryke_command = "tryke",
        python = "/repo/.venv/bin/python3",
        tryke_log_level = "debug",
      }
      local args, env = server._build_spawn_options(cfg, 9000)
      assert.same(
        { "server", "--port", "9000", "--python", "/repo/.venv/bin/python3" },
        args
      )
      table.sort(env)
      assert.same({ "PATH=/usr/bin", "TRYKE_LOG=debug" }, env)
    end)
  end)
end)
