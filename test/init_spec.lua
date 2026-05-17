local adapter = require("neotest-tryke")
local Tree = require("neotest.types").Tree

local function build_tree(list)
  return Tree.from_list(list, function(pos)
    return pos.id
  end)
end

describe("collect_test_ids", function()
  it("returns a single-element list for a test position", function()
    local tree = build_tree({
      {
        type = "test",
        path = "/proj/tests/math.py",
        name = "test_add",
        id = "/proj/tests/math.py::test_add",
        range = { 0, 0, 0, 0 },
      },
    })
    local ids = adapter._collect_test_ids(tree, tree:data(), "/proj")
    assert.same({ "tests/math.py::test_add" }, ids)
  end)

  it("collects every test under a file in tree-iter order", function()
    local tree = build_tree({
      {
        type = "file",
        path = "/proj/tests/math.py",
        name = "math.py",
        id = "/proj/tests/math.py",
        range = { 0, 0, 10, 0 },
      },
      {
        {
          type = "test",
          path = "/proj/tests/math.py",
          name = "test_add",
          id = "/proj/tests/math.py::test_add",
          range = { 0, 0, 0, 0 },
        },
      },
      {
        {
          type = "test",
          path = "/proj/tests/math.py",
          name = "test_sub",
          id = "/proj/tests/math.py::test_sub",
          range = { 1, 0, 1, 0 },
        },
      },
    })
    local ids = adapter._collect_test_ids(tree, tree:data(), "/proj")
    assert.same({
      "tests/math.py::test_add",
      "tests/math.py::test_sub",
    }, ids)
  end)

  it("drops describe-block group segments — server's TestItem::id() omits them", function()
    -- `with t.describe("Channel"):` produces a `Channel` namespace whose
    -- children's neotest ids include "::Channel::". The server's id
    -- format is just {relative_path}::{name}, so groups must be stripped
    -- when sending to it (otherwise it picks up zero tests).
    local tree = build_tree({
      {
        type = "file",
        path = "/proj/src/proj/channels.py",
        name = "channels.py",
        id = "/proj/src/proj/channels.py",
        range = { 0, 0, 20, 0 },
      },
      {
        {
          type = "namespace",
          path = "/proj/src/proj/channels.py",
          name = "Channel",
          id = "/proj/src/proj/channels.py::Channel",
          range = { 0, 0, 20, 0 },
        },
        {
          {
            type = "test",
            path = "/proj/src/proj/channels.py",
            name = "test_basic",
            id = "/proj/src/proj/channels.py::Channel::test_basic",
            range = { 5, 0, 5, 0 },
          },
        },
      },
    })
    local ids = adapter._collect_test_ids(tree, tree:data(), "/proj")
    assert.same({ "src/proj/channels.py::test_basic" }, ids)
  end)

  it("skips non-test nodes when descending namespaces", function()
    local tree = build_tree({
      {
        type = "file",
        path = "/proj/tests/math.py",
        name = "math.py",
        id = "/proj/tests/math.py",
        range = { 0, 0, 10, 0 },
      },
      {
        {
          type = "namespace",
          path = "/proj/tests/math.py",
          name = "Math",
          id = "/proj/tests/math.py::Math",
          range = { 0, 0, 10, 0 },
        },
        {
          {
            type = "test",
            path = "/proj/tests/math.py",
            name = "test_add",
            id = "/proj/tests/math.py::Math::test_add",
            range = { 1, 0, 1, 0 },
          },
        },
      },
      {
        {
          type = "test",
          path = "/proj/tests/math.py",
          name = "test_top",
          id = "/proj/tests/math.py::test_top",
          range = { 5, 0, 5, 0 },
        },
      },
    })
    local ids = adapter._collect_test_ids(tree, tree:data(), "/proj")
    assert.same({
      "tests/math.py::test_add",
      "tests/math.py::test_top",
    }, ids)
  end)

  it("preserves [case_label] suffixes in the leaf segment", function()
    -- `name` already carries `[case_label]` for parametrised cases — the
    -- server matches on the full leaf, so we must keep it intact.
    local tree = build_tree({
      {
        type = "file",
        path = "/abs/proj/tests/cases.py",
        name = "cases.py",
        id = "/abs/proj/tests/cases.py",
        range = { 0, 0, 20, 0 },
      },
      {
        {
          type = "test",
          path = "/abs/proj/tests/cases.py",
          name = "square[zero]",
          id = "/abs/proj/tests/cases.py::square[zero]",
          range = { 3, 0, 3, 0 },
        },
      },
      {
        {
          type = "test",
          path = "/abs/proj/tests/cases.py",
          name = "square[one]",
          id = "/abs/proj/tests/cases.py::square[one]",
          range = { 4, 0, 4, 0 },
        },
      },
    })
    local ids = adapter._collect_test_ids(tree, tree:data(), "/abs/proj")
    assert.same({
      "tests/cases.py::square[zero]",
      "tests/cases.py::square[one]",
    }, ids)
  end)

  it("uses _func_name when set (display-name and doctest cases)", function()
    -- `@test("nice display")` and doctests both store the python symbol
    -- on `_func_name` and the user-facing label on `name`. The server
    -- runs by symbol, so the leaf has to come from `_func_name`.
    local tree = build_tree({
      {
        type = "file",
        path = "/proj/tests/foo.py",
        name = "foo.py",
        id = "/proj/tests/foo.py",
        range = { 0, 0, 10, 0 },
      },
      {
        {
          type = "test",
          path = "/proj/tests/foo.py",
          name = "nice display",
          _func_name = "test_actual_symbol",
          id = "/proj/tests/foo.py::test_actual_symbol",
          range = { 0, 0, 0, 0 },
        },
      },
      {
        {
          type = "test",
          path = "/proj/tests/foo.py",
          name = "doctest: Counter.increment",
          _func_name = "Counter.increment",
          id = "/proj/tests/foo.py::Counter.increment",
          range = { 1, 0, 1, 0 },
        },
      },
    })
    local ids = adapter._collect_test_ids(tree, tree:data(), "/proj")
    assert.same({
      "tests/foo.py::test_actual_symbol",
      "tests/foo.py::Counter.increment",
    }, ids)
  end)

  it("returns just the position's own id when given a test (not the whole tree)", function()
    -- When the user runs a single test, build_server_spec passes the
    -- test position itself — the helper must use `position` directly
    -- rather than walking the (possibly larger) tree.
    local tree = build_tree({
      {
        type = "file",
        path = "/proj/tests/math.py",
        name = "math.py",
        id = "/proj/tests/math.py",
        range = { 0, 0, 10, 0 },
      },
      {
        {
          type = "test",
          path = "/proj/tests/math.py",
          name = "test_add",
          id = "/proj/tests/math.py::test_add",
          range = { 0, 0, 0, 0 },
        },
      },
      {
        {
          type = "test",
          path = "/proj/tests/math.py",
          name = "test_sub",
          id = "/proj/tests/math.py::test_sub",
          range = { 1, 0, 1, 0 },
        },
      },
    })
    local test_node = tree:children()[1]
    local ids = adapter._collect_test_ids(test_node, test_node:data(), "/proj")
    assert.same({ "tests/math.py::test_add" }, ids)
  end)

  it("leaves the absolute path in place when no root is supplied (defensive)", function()
    local tree = build_tree({
      {
        type = "test",
        path = "/proj/tests/math.py",
        name = "test_add",
        id = "/proj/tests/math.py::test_add",
        range = { 0, 0, 0, 0 },
      },
    })
    local ids = adapter._collect_test_ids(tree, tree:data(), nil)
    assert.same({ "/proj/tests/math.py::test_add" }, ids)
  end)
end)

describe("collect_test_file_paths", function()
  -- Sent to the server via `did_change` BEFORE `run` so it can mark the
  -- worker pool dirty and refresh discovery on the same TCP connection.
  -- The ordering matters because the server reads requests serially per
  -- connection; the contents matter because the server uses the paths
  -- both for `affected_modules` and as a defence-in-depth project-root
  -- filter. Tests below exercise the three branches the helper has:
  -- single test position, tree iteration over multiple tests, and
  -- dedup-via-`seen`.

  it("returns a single-element list for a test position", function()
    local tree = build_tree({
      {
        type = "test",
        path = "/proj/tests/math.py",
        name = "test_add",
        id = "/proj/tests/math.py::test_add",
        range = { 0, 0, 0, 0 },
      },
    })
    local paths = adapter._collect_test_file_paths(tree, tree:data())
    assert.same({ "/proj/tests/math.py" }, paths)
  end)

  it("collects every unique file under a file position via tree iteration", function()
    -- All tests share one file → dedup keeps the file in the result
    -- exactly once.
    local tree = build_tree({
      {
        type = "file",
        path = "/proj/tests/math.py",
        name = "math.py",
        id = "/proj/tests/math.py",
        range = { 0, 0, 10, 0 },
      },
      {
        {
          type = "test",
          path = "/proj/tests/math.py",
          name = "test_add",
          id = "/proj/tests/math.py::test_add",
          range = { 0, 0, 0, 0 },
        },
      },
      {
        {
          type = "test",
          path = "/proj/tests/math.py",
          name = "test_sub",
          id = "/proj/tests/math.py::test_sub",
          range = { 1, 0, 1, 0 },
        },
      },
    })
    local paths = adapter._collect_test_file_paths(tree, tree:data())
    assert.same({ "/proj/tests/math.py" }, paths)
  end)

  it("returns one entry per distinct file when tests span multiple files", function()
    -- A dir-level run drains tests from multiple files; the helper
    -- must report each file exactly once (no duplicates) so the
    -- server's `did_change` payload is minimal and the affected-modules
    -- gate doesn't over-restart.
    local tree = build_tree({
      {
        type = "dir",
        path = "/proj/tests",
        name = "tests",
        id = "/proj/tests",
        range = { 0, 0, 0, 0 },
      },
      {
        {
          type = "file",
          path = "/proj/tests/math.py",
          name = "math.py",
          id = "/proj/tests/math.py",
          range = { 0, 0, 5, 0 },
        },
        {
          {
            type = "test",
            path = "/proj/tests/math.py",
            name = "test_add",
            id = "/proj/tests/math.py::test_add",
            range = { 0, 0, 0, 0 },
          },
        },
      },
      {
        {
          type = "file",
          path = "/proj/tests/strings.py",
          name = "strings.py",
          id = "/proj/tests/strings.py",
          range = { 0, 0, 5, 0 },
        },
        {
          {
            type = "test",
            path = "/proj/tests/strings.py",
            name = "test_upper",
            id = "/proj/tests/strings.py::test_upper",
            range = { 0, 0, 0, 0 },
          },
        },
      },
    })
    local paths = adapter._collect_test_file_paths(tree, tree:data())
    table.sort(paths)
    assert.same({ "/proj/tests/math.py", "/proj/tests/strings.py" }, paths)
  end)

  it("returns an empty list when the tree has no test positions", function()
    -- A `file` position with no `test` children (e.g. discovery
    -- failed) should not produce a phantom path.
    local tree = build_tree({
      {
        type = "file",
        path = "/proj/tests/empty.py",
        name = "empty.py",
        id = "/proj/tests/empty.py",
        range = { 0, 0, 0, 0 },
      },
    })
    local paths = adapter._collect_test_file_paths(tree, tree:data())
    assert.same({}, paths)
  end)
end)

describe("build_direct_argv", function()
  -- Direct-mode argv is the runner's primary contract: it controls the
  -- argv passed to `tryke test` and any env (TRYKE_LOG) the child sees.
  -- Argument ordering and `env` shape regress easily, so each option
  -- gets a dedicated assertion. Tested at the pure-helper level
  -- (`_build_direct_argv`) so the streaming-results scaffolding in
  -- `build_direct_spec` doesn't drag in `neotest.lib.file`.

  local function file_tree()
    return require("neotest.types").Tree.from_list({
      type = "file",
      path = "/proj/tests/math.py",
      name = "math.py",
      id = "/proj/tests/math.py",
      range = { 0, 0, 10, 0 },
    }, function(pos)
      return pos.id
    end)
  end

  local function default_cfg(overrides)
    -- Mirror the shape `config.get` produces — `_build_direct_argv` reads
    -- many fields and missing-key access would be an unrelated error.
    local base = {
      tryke_command = "tryke",
      python = nil,
      tryke_log_level = nil,
      args = {},
      workers = nil,
      fail_fast = false,
    }
    for k, v in pairs(overrides or {}) do
      base[k] = v
    end
    return base
  end

  it("threads `--python <path>` into the argv", function()
    local argv = adapter._build_direct_argv(
      { tree = file_tree() },
      default_cfg({ python = "/proj/.venv/bin/python3" }),
      "/proj"
    )
    -- Pin the exact pair so a regression in argv ordering (e.g.
    -- `--python` ending up before `test`) surfaces immediately.
    local found_at = nil
    for i, arg in ipairs(argv) do
      if arg == "--python" then
        found_at = i
      end
    end
    assert.is_truthy(found_at, "expected --python in argv: " .. table.concat(argv, " "))
    assert.equal("/proj/.venv/bin/python3", argv[found_at + 1])
  end)

  it("returns env with TRYKE_LOG when tryke_log_level is configured", function()
    local _, env = adapter._build_direct_argv(
      { tree = file_tree() },
      default_cfg({ tryke_log_level = "info" }),
      "/proj"
    )
    assert.same({ TRYKE_LOG = "info" }, env)
  end)

  it("returns nil env when tryke_log_level is unset", function()
    -- A nil env means neotest forwards the parent's full environment.
    -- Setting `{}` here would (depending on the runner's spawn helper)
    -- give the child no env at all, which would break PATH lookup.
    local _, env = adapter._build_direct_argv({ tree = file_tree() }, default_cfg(), "/proj")
    assert.is_nil(env)
  end)

  it("omits --python from argv when no python is configured", function()
    local argv = adapter._build_direct_argv({ tree = file_tree() }, default_cfg(), "/proj")
    for _, arg in ipairs(argv) do
      assert.are_not.equal("--python", arg)
    end
  end)
end)
