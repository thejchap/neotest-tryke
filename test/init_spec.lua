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
