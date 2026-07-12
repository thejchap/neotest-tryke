local nio = require("nio")
local a = nio.tests
local cli = require("neotest-tryke.cli_discovery")

local function collect(tree)
  local out = {}
  for _, pos in tree:iter() do
    table.insert(out, pos)
  end
  return out
end

-- Replace `vim.system` for the duration of a test so we can feed the
-- parser canned stdout without actually spawning tryke. The mock matches
-- the async form used by `spawn_collect` — it invokes the completion
-- callback instead of returning a waitable handle. Every spawned argv is
-- collected into the table passed to `fn`, so specs can assert on both
-- argv shape (e.g. `--python` plumbing) and spawn counts (batching).
-- Restores the original on teardown.
local function with_mock_system(stdout_lines, fn)
  local original = vim.system
  local cmds = {}
  vim.system = function(cmd, _opts, on_exit)
    table.insert(cmds, cmd)
    on_exit({ code = 0, stdout = table.concat(stdout_lines, "\n"), stderr = "" })
    return {}
  end
  local ok, err = pcall(fn, cmds)
  vim.system = original
  if not ok then
    error(err)
  end
end

-- Like `with_mock_system` but every spawn exits with `code`.
local function with_failing_system(code, fn)
  local original = vim.system
  local cmds = {}
  vim.system = function(cmd, _opts, on_exit)
    table.insert(cmds, cmd)
    on_exit({ code = code, stdout = "", stderr = "boom" })
    return {}
  end
  local ok, err = pcall(fn, cmds)
  vim.system = original
  if not ok then
    error(err)
  end
end

-- Swap in a fake `neotest-tryke.server` module (server_refresh requires
-- it lazily) and restore the real one on teardown.
local function with_fake_server(stub, fn)
  local original = package.loaded["neotest-tryke.server"]
  package.loaded["neotest-tryke.server"] = stub
  local ok, err = pcall(fn)
  package.loaded["neotest-tryke.server"] = original
  if not ok then
    error(err)
  end
end

local function emit(tests)
  return vim.json.encode({ event = "collect_complete", tests = tests })
end

local function cfg(extra)
  return vim.tbl_extend("force", { tryke_command = "tryke" }, extra or {})
end

describe("cli_discovery", function()
  before_each(function()
    cli.reset()
  end)

  a.it("builds file > test for a single top-level test", function()
    local tree
    with_mock_system({ emit({
      { name = "test_addition", file_path = "tests/t.py", line_number = 4, groups = {} },
    }) }, function()
      tree = cli.discover("/proj/tests/t.py", "/proj", cfg())
    end)
    local positions = collect(tree)
    assert.equal(2, #positions)
    assert.equal("file", positions[1].type)
    assert.equal("test", positions[2].type)
    assert.equal("/proj/tests/t.py::test_addition", positions[2].id)
    assert.equal("test_addition", positions[2].name)
  end)

  a.it("nests tests under a describe namespace", function()
    local tree
    with_mock_system({ emit({
      { name = "test_basic", file_path = "src/a.py", line_number = 16, groups = { "Channel" } },
    }) }, function()
      tree = cli.discover("/proj/src/a.py", "/proj", cfg())
    end)
    local positions = collect(tree)
    assert.equal("file", positions[1].type)
    assert.equal("namespace", positions[2].type)
    assert.equal("Channel", positions[2].name)
    assert.equal("/proj/src/a.py::Channel", positions[2].id)
    assert.equal("test", positions[3].type)
    assert.equal("/proj/src/a.py::Channel::test_basic", positions[3].id)
  end)

  a.it("reuses the same namespace for siblings under the same describe", function()
    local tree
    with_mock_system({ emit({
      { name = "a", file_path = "t.py", line_number = 1, groups = { "Group" } },
      { name = "b", file_path = "t.py", line_number = 2, groups = { "Group" } },
    }) }, function()
      tree = cli.discover("/proj/t.py", "/proj", cfg())
    end)
    local namespaces = 0
    for _, pos in ipairs(collect(tree)) do
      if pos.type == "namespace" then
        namespaces = namespaces + 1
      end
    end
    assert.equal(1, namespaces, "both tests should share one Group namespace")
  end)

  a.it("expands @test.cases into one position per case label", function()
    local tree
    with_mock_system({ emit({
      { name = "square", file_path = "t.py", line_number = 10, case_label = "zero", case_index = 0 },
      { name = "square", file_path = "t.py", line_number = 10, case_label = "one", case_index = 1 },
    }) }, function()
      tree = cli.discover("/proj/t.py", "/proj", cfg())
    end)
    local ids = {}
    for _, pos in ipairs(collect(tree)) do
      if pos.type == "test" then
        table.insert(ids, pos.id)
      end
    end
    assert.is_true(vim.tbl_contains(ids, "/proj/t.py::square[zero]"))
    assert.is_true(vim.tbl_contains(ids, "/proj/t.py::square[one]"))
  end)

  a.it("composes display_name and case_label for labelled @test.cases rows", function()
    -- Regression: `@test("basic").cases(case("1+1"), case("1+2"))` sets
    -- both `display_name="basic"` and a per-row `case_label`. The old
    -- code took the case branch first and showed the function leaf
    -- (`labelled_addition[1+1]`) instead of `basic[1+1]`, collapsing the
    -- function-level label entirely. `_func_name` keeps the runner-facing
    -- leaf so server-mode `to_server_id` still matches `TestItem::id()`.
    local tree
    with_mock_system({ emit({
      {
        name = "labelled_addition",
        file_path = "t.py",
        line_number = 4,
        display_name = "basic",
        case_label = "1 + 1",
        case_index = 0,
      },
      {
        name = "labelled_addition",
        file_path = "t.py",
        line_number = 4,
        display_name = "basic",
        case_label = "1 + 2",
        case_index = 1,
      },
    }) }, function()
      tree = cli.discover("/proj/t.py", "/proj", cfg())
    end)
    local names = {}
    local func_names = {}
    for _, p in ipairs(collect(tree)) do
      if p.type == "test" then
        table.insert(names, p.name)
        table.insert(func_names, p._func_name)
      end
    end
    assert.is_true(vim.tbl_contains(names, "basic[1 + 1]"))
    assert.is_true(vim.tbl_contains(names, "basic[1 + 2]"))
    assert.is_true(vim.tbl_contains(func_names, "labelled_addition[1 + 1]"))
    assert.is_true(vim.tbl_contains(func_names, "labelled_addition[1 + 2]"))
  end)

  a.it("uses display_name as position name but keeps test.name on _func_name", function()
    local tree
    with_mock_system({ emit({
      { name = "test_basic", file_path = "t.py", line_number = 4, display_name = "basic equality" },
    }) }, function()
      tree = cli.discover("/proj/t.py", "/proj", cfg())
    end)
    local positions = collect(tree)
    local test_pos
    for _, p in ipairs(positions) do
      if p.type == "test" then
        test_pos = p
      end
    end
    assert.equal("basic equality", test_pos.name)
    assert.equal("test_basic", test_pos._func_name)
    -- Result-mapping id uses the python name, not the display label.
    assert.equal("/proj/t.py::test_basic", test_pos.id)
  end)

  a.it("marks doctest positions with _is_doctest", function()
    local tree
    with_mock_system({ emit({
      {
        name = "Counter.increment",
        file_path = "m.py",
        line_number = 20,
        display_name = "doctest: Counter.increment",
        doctest_object = "Counter.increment",
      },
    }) }, function()
      tree = cli.discover("/proj/m.py", "/proj", cfg())
    end)
    local dt
    for _, p in ipairs(collect(tree)) do
      if p.type == "test" then
        dt = p
      end
    end
    assert.is_true(dt._is_doctest)
    assert.equal("doctest: Counter.increment", dt.name)
    assert.equal("Counter.increment", dt._func_name)
  end)

  a.it("returns nil when tryke reports zero tests", function()
    local tree
    with_mock_system({ emit({}) }, function()
      tree = cli.discover("/proj/t.py", "/proj", cfg())
    end)
    assert.is_nil(tree)
  end)

  a.it("resolves per-case source lines for @test.cases rows", function()
    -- Write a real file so find_case_line has something to scan.
    local tmp = vim.fn.tempname() .. ".py"
    local f = assert(io.open(tmp, "w"))
    f:write(table.concat({
      "from tryke import expect, test",
      "",
      "@test.cases(",
      '    test.case("zero", n=0, expected=0),',
      '    test.case("one", n=1, expected=1),',
      "    ten={\"n\": 10, \"expected\": 100},",
      ")",
      "def square(n: int, expected: int) -> None:",
      "    expect(n * n).to_equal(expected)",
    }, "\n"))
    f:close()
    -- Backdate the mtime so the file predates the collect and the cached
    -- entry counts as fresh.
    local past = os.time() - 10
    vim.uv.fs_utime(tmp, past, past)
    -- `line_number` matches the decorated function, just like tryke emits.
    local tree
    with_mock_system({ emit({
      { name = "square", file_path = tmp, line_number = 8, case_label = "zero", case_index = 0 },
      { name = "square", file_path = tmp, line_number = 8, case_label = "one", case_index = 1 },
      { name = "square", file_path = tmp, line_number = 8, case_label = "ten", case_index = 2 },
    }) }, function()
      tree = cli.discover(tmp, "/tmp", cfg())
    end)
    os.remove(tmp)

    local lines_by_id = {}
    for _, pos in ipairs(collect(tree)) do
      if pos.type == "test" then
        lines_by_id[pos.id] = pos.range[1] + 1
      end
    end
    assert.equal(4, lines_by_id[tmp .. "::square[zero]"], "typed form zero → line 4")
    assert.equal(5, lines_by_id[tmp .. "::square[one]"], "typed form one → line 5")
    assert.equal(6, lines_by_id[tmp .. "::square[ten]"], "kwargs form ten → line 6")
  end)

  a.it("forwards the python interpreter as `--python <path>` when provided", function()
    -- Discovery must use the same interpreter as execution; otherwise the
    -- test tree silently fails to populate when system python lacks the
    -- project's tryke package. The assertion also pins the batch shape:
    -- no positional path — one spawn covers the whole project.
    with_mock_system({ emit({}) }, function(cmds)
      cli.discover("/proj/t.py", "/proj", cfg({ python = "/proj/.venv/bin/python3" }))
      assert.same({
        "tryke",
        "test",
        "--collect-only",
        "--reporter",
        "json",
        "--python",
        "/proj/.venv/bin/python3",
      }, cmds[1])
    end)
  end)

  a.it("omits --python when no python is provided", function()
    -- nil python means "let tryke pick" (PATH default); the flag must
    -- not be inserted, otherwise tryke would fail with a missing-arg
    -- error or pass an empty string as the interpreter path.
    with_mock_system({ emit({}) }, function(cmds)
      cli.discover("/proj/t.py", "/proj", cfg())
      for _, cmd in ipairs(cmds) do
        for _, arg in ipairs(cmd) do
          assert.are_not.equal("--python", arg, "--python should be absent when python=nil")
        end
      end
    end)
  end)

  a.it("collects the single file directly when no root is known", function()
    with_mock_system({ emit({
      { name = "t", file_path = "/abs/t.py", line_number = 1 },
    }) }, function(cmds)
      local tree = cli.discover("/abs/t.py", nil, cfg())
      assert.same({ "tryke", "test", "/abs/t.py", "--collect-only", "--reporter", "json" }, cmds[1])
      assert.is_not_nil(tree)
    end)
  end)

  a.it("serves every file in the root from one whole-project spawn", function()
    -- The whole point of the batch: neotest's project scan calls
    -- discover_positions once per test file, and per-file spawns are
    -- what stalled the editor.
    local tree_a, tree_b
    with_mock_system({ emit({
      { name = "test_a", file_path = "tests/a.py", line_number = 1 },
      { name = "test_b", file_path = "tests/b.py", line_number = 1 },
    }) }, function(cmds)
      tree_a = cli.discover("/proj/tests/a.py", "/proj", cfg())
      tree_b = cli.discover("/proj/tests/b.py", "/proj", cfg())
      assert.equal(1, #cmds, "second file must be served from the cached batch")
    end)
    assert.equal("/proj/tests/a.py::test_a", collect(tree_a)[2].id)
    assert.equal("/proj/tests/b.py::test_b", collect(tree_b)[2].id)
  end)

  a.it("returns nil without respawning for a file the batch found no tests in", function()
    local tmp = vim.fn.tempname() .. ".py"
    local f = assert(io.open(tmp, "w"))
    f:write("x = 1\n")
    f:close()
    local past = os.time() - 10
    vim.uv.fs_utime(tmp, past, past)
    local root = vim.fs.dirname(tmp)
    with_mock_system({ emit({
      { name = "other", file_path = "tests/other.py", line_number = 1 },
    }) }, function(cmds)
      local tree = cli.discover(tmp, root, cfg())
      assert.is_nil(tree)
      assert.equal(1, #cmds, "absence from a complete snapshot must not trigger a spawn")
    end)
    os.remove(tmp)
  end)

  a.it("recollects just the file when it changes after the batch", function()
    local tmp = vim.fn.tempname() .. ".py"
    local f = assert(io.open(tmp, "w"))
    f:write("from tryke import test\n")
    f:close()
    local past = os.time() - 10
    vim.uv.fs_utime(tmp, past, past)
    local root = vim.fs.dirname(tmp)
    local rel = tmp:sub(#root + 2)
    with_mock_system({ emit({
      { name = "test_x", file_path = tmp, line_number = 1 },
    }) }, function(cmds)
      local tree = cli.discover(tmp, root, cfg())
      assert.equal(1, #cmds)
      assert.is_not_nil(tree)
      -- Simulate a save after the batch.
      local future_time = os.time() + 10
      vim.uv.fs_utime(tmp, future_time, future_time)
      tree = cli.discover(tmp, root, cfg())
      assert.equal(2, #cmds, "a stale entry must trigger exactly one targeted respawn")
      assert.same({ "tryke", "test", rel, "--collect-only", "--reporter", "json" }, cmds[2])
      assert.is_not_nil(tree)
    end)
    os.remove(tmp)
  end)

  a.it("errors fast on repeated batch failures without respawning", function()
    with_failing_system(1, function(cmds)
      local ok = pcall(cli.discover, "/proj/tests/t.py", "/proj", cfg())
      assert.is_false(ok)
      assert.equal(1, #cmds)
      local ok2, err2 = pcall(cli.discover, "/proj/tests/t.py", "/proj", cfg())
      assert.is_false(ok2)
      assert.matches("backing off", tostring(err2))
      assert.equal(1, #cmds, "the backoff must prevent a second spawn")
    end)
  end)

  a.it("prefers the running server's discover RPC over spawning", function()
    with_fake_server({
      RPC = { OK = "ok" },
      is_running = function()
        return true
      end,
      request_with_timeout = function()
        return {
          result = { tests = { { name = "test_srv", file_path = "tests/t.py", line_number = 1 } } },
        }, "ok"
      end,
      send_did_change = function()
        return "acked"
      end,
    }, function()
      with_mock_system({ emit({}) }, function(cmds)
        local tree = cli.discover("/proj/tests/t.py", "/proj", cfg({ mode = "server" }))
        assert.equal(0, #cmds, "server-mode discovery must not spawn a process")
        assert.equal("/proj/tests/t.py::test_srv", collect(tree)[2].id)
      end)
    end)
  end)

  a.it("falls back to a one-shot CLI batch when the server discover times out", function()
    with_fake_server({
      RPC = { OK = "ok", TIMEOUT = "timeout" },
      is_running = function()
        return true
      end,
      request_with_timeout = function()
        return nil, "timeout"
      end,
      send_did_change = function()
        return "acked"
      end,
    }, function()
      with_mock_system({ emit({
        { name = "test_cli", file_path = "tests/t.py", line_number = 1 },
      }) }, function(cmds)
        local tree = cli.discover("/proj/tests/t.py", "/proj", cfg({ mode = "server" }))
        assert.equal(1, #cmds, "expected exactly one fallback batch spawn")
        assert.equal("/proj/tests/t.py::test_cli", collect(tree)[2].id)
      end)
    end)
  end)
end)
