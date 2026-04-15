local ts = require("neotest-tryke.treesitter")

local fixtures = vim.fn.fnamemodify("test/fixtures", ":p")

describe("is_test_file", function()
  it("returns true for file with tryke import", function()
    assert.is_true(ts.is_test_file(fixtures .. "tryke_test.py"))
  end)

  it("returns false for Python file without tryke imports", function()
    assert.is_false(ts.is_test_file(fixtures .. "plain_python.py"))
  end)

  it("returns false for non-Python file", function()
    assert.is_false(ts.is_test_file(fixtures .. "not_python.txt"))
  end)

  it("returns false for non-existent file", function()
    assert.is_false(ts.is_test_file(fixtures .. "does_not_exist.py"))
  end)

  it("returns false when import is beyond line 50", function()
    assert.is_false(ts.is_test_file(fixtures .. "late_import.py"))
  end)

  it("returns true for file with describe blocks", function()
    assert.is_true(ts.is_test_file(fixtures .. "describe_test.py"))
  end)
end)

describe("_build_position with @test.cases", function()
  local source = [[
from tryke import describe, expect, test


@test.cases(
    zero={"n": 0, "squared": 0},
    one={"n": 1, "squared": 1},
    two={"n": 2, "squared": 4},
)
def square(n: int, squared: int) -> None:
    expect(n * n).to_equal(squared)


@test.cases([("2 + 3", {"a": 2, "b": 3, "total": 5})])
def add(a: int, b: int, total: int) -> None:
    expect(a + b).to_equal(total)
]]

  --- Walk a parsed tree, running the query and invoking `_build_position` on
  --- every match. Returns the flattened list of positions. Mirrors what
  --- `neotest.lib.treesitter.collect` does but without the neotest dep.
  local function collect_positions(src)
    local parser = vim.treesitter.get_string_parser(src, "python", {
      injections = { python = "" },
    })
    local root = parser:parse()[1]:root()
    local parsed_query = vim.treesitter.query.parse("python", ts.query)
    local positions = {}
    for _, match in parsed_query:iter_matches(root, src, nil, nil, { all = false }) do
      local captured_nodes = {}
      for i, capture in ipairs(parsed_query.captures) do
        captured_nodes[capture] = match[i]
      end
      local res = ts._build_position("cases.py", src, captured_nodes)
      if res then
        if res[1] then
          for _, p in ipairs(res) do
            table.insert(positions, p)
          end
        else
          table.insert(positions, res)
        end
      end
    end
    return positions
  end

  local function names_of(positions)
    local names = {}
    for _, pos in ipairs(positions) do
      table.insert(names, pos.name)
    end
    return names
  end

  it("expands kwargs form into one position per case", function()
    local names = names_of(collect_positions(source))
    assert.is_true(vim.tbl_contains(names, "square[zero]"))
    assert.is_true(vim.tbl_contains(names, "square[one]"))
    assert.is_true(vim.tbl_contains(names, "square[two]"))
  end)

  it("expands list form into one position per label", function()
    local names = names_of(collect_positions(source))
    assert.is_true(vim.tbl_contains(names, "add[2 + 3]"))
  end)

  it("does not emit a bare function position for @test.cases", function()
    local names = names_of(collect_positions(source))
    assert.is_false(vim.tbl_contains(names, "square"))
    assert.is_false(vim.tbl_contains(names, "add"))
  end)

  it("suppresses the generic match when @test.skip stacks on @test.cases", function()
    local stacked = [[
from tryke import test

@test.skip("reason")
@test.cases(a={"x": 1}, b={"x": 2})
def skipped(x: int) -> None:
    pass
]]
    local names = names_of(collect_positions(stacked))
    assert.is_true(vim.tbl_contains(names, "skipped[a]"))
    assert.is_true(vim.tbl_contains(names, "skipped[b]"))
    -- No bare function position — the cases pattern owns the expansion,
    -- so a duplicate "skipped" entry would only clutter the tree.
    assert.is_false(vim.tbl_contains(names, "skipped"))
  end)
end)
