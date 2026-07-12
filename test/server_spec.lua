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

  it("emits a bare `server` for a default config — stdio transport has no --port", function()
    local cfg = { tryke_command = "tryke" }
    local args, env = server._build_spawn_options(cfg)
    assert.same({ "server" }, args)
    -- No log level → no env override → libuv inherits parent env.
    assert.is_nil(env)
  end)

  it("appends --python when config.python is set", function()
    -- Order matters: tryke parses positional args in order, so `--python`
    -- must come after the subcommand but before any positional paths.
    local cfg = { tryke_command = "tryke", python = "/repo/.venv/bin/python3" }
    local args = server._build_spawn_options(cfg)
    assert.same({ "server", "--python", "/repo/.venv/bin/python3" }, args)
  end)

  it("splices parent env and appends TRYKE_LOG when tryke_log_level is set", function()
    with_os_environ({ PATH = "/usr/bin", HOME = "/home/u" }, function()
      local cfg = { tryke_command = "tryke", tryke_log_level = "info" }
      local _, env = server._build_spawn_options(cfg)
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
      local _, env = server._build_spawn_options(cfg)
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
      local args, env = server._build_spawn_options(cfg)
      assert.same({ "server", "--python", "/repo/.venv/bin/python3" }, args)
      table.sort(env)
      assert.same({ "PATH=/usr/bin", "TRYKE_LOG=debug" }, env)
    end)
  end)
end)

describe("server._classify_reply", function()
  it("maps a timeout to TIMEOUT", function()
    assert.equal(server.RPC.TIMEOUT, server._classify_reply(true, nil, nil))
  end)

  it("maps a transport error to ERROR", function()
    assert.equal(server.RPC.ERROR, server._classify_reply(false, "closed", nil))
  end)

  it("maps METHOD_NOT_FOUND to UNSUPPORTED", function()
    local resp = { error = { code = -32601, message = "method not found" } }
    assert.equal(server.RPC.UNSUPPORTED, server._classify_reply(false, nil, resp))
  end)

  it("maps any other server error to ERROR", function()
    local resp = { error = { code = -32603, message = "internal" } }
    assert.equal(server.RPC.ERROR, server._classify_reply(false, nil, resp))
  end)

  it("maps a reply with neither result nor error to MALFORMED", function()
    assert.equal(server.RPC.MALFORMED, server._classify_reply(false, nil, {}))
    assert.equal(server.RPC.MALFORMED, server._classify_reply(false, nil, nil))
  end)

  it("maps a reply with a result to OK", function()
    local resp = { result = { tests = {} } }
    assert.equal(server.RPC.OK, server._classify_reply(false, nil, resp))
  end)
end)

describe("server.is_running", function()
  it("is false before any server has been spawned", function()
    -- With the stdio transport the child process IS the connection;
    -- callers must be able to cheaply check for one before sending.
    assert.is_false(server.is_running())
  end)

  it("send_request errors instead of writing into the void", function()
    -- The old TCP code wrote to a module-global socket handle and
    -- crashed with a nil-index if nothing had connected. The stdio
    -- transport makes the precondition explicit.
    local ok, err = pcall(server.send_request, "ping")
    assert.is_false(ok)
    assert.matches("not running", tostring(err))
  end)

  it("request_with_timeout returns ERROR instead of throwing when the server is down", function()
    -- Discovery treats the server as an optimisation: a dead transport
    -- must map to a fallback signal, not a crash at the call site.
    local resp, outcome = server.request_with_timeout("discover", nil, 100)
    assert.is_nil(resp)
    assert.equal(server.RPC.ERROR, outcome)
  end)
end)
