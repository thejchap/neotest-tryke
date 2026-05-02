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

  it("descends through namespaces and skips non-test nodes", function()
    -- File > namespace `Math` > test_add, plus a sibling top-level test.
    -- The returned list must contain only `type == "test"` ids.
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
      "tests/math.py::Math::test_add",
      "tests/math.py::test_top",
    }, ids)
  end)

  it("preserves group separators and [case_label] suffixes after stripping root", function()
    -- The server expects {relative_path}::{groups...}::{name[case_label]?}
    -- — only the leading absolute path is rewritten relative to root.
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
          type = "namespace",
          path = "/abs/proj/tests/cases.py",
          name = "Math",
          id = "/abs/proj/tests/cases.py::Math",
          range = { 0, 0, 20, 0 },
        },
        {
          {
            type = "namespace",
            path = "/abs/proj/tests/cases.py",
            name = "addition",
            id = "/abs/proj/tests/cases.py::Math::addition",
            range = { 0, 0, 20, 0 },
          },
          {
            {
              type = "test",
              path = "/abs/proj/tests/cases.py",
              name = "square[zero]",
              id = "/abs/proj/tests/cases.py::Math::addition::square[zero]",
              range = { 3, 0, 3, 0 },
            },
          },
          {
            {
              type = "test",
              path = "/abs/proj/tests/cases.py",
              name = "square[one]",
              id = "/abs/proj/tests/cases.py::Math::addition::square[one]",
              range = { 4, 0, 4, 0 },
            },
          },
        },
      },
    })
    local ids = adapter._collect_test_ids(tree, tree:data(), "/abs/proj")
    assert.same({
      "tests/cases.py::Math::addition::square[zero]",
      "tests/cases.py::Math::addition::square[one]",
    }, ids)
  end)

  it("returns just the position's own id when given a test (not the whole tree)", function()
    -- When the user runs a single test, build_server_spec passes the
    -- test position itself — the helper must use `position.id` directly
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

  it("leaves ids untouched when no root is supplied (defensive — should not happen in practice)", function()
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
