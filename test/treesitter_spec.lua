local ts = require("neotest-tryke.treesitter")

local fixtures = vim.fn.fnamemodify("test/fixtures", ":p")

local function parse_positions(file_path)
  local content = io.open(file_path, "r"):read("*a")
  local lang_tree = vim.treesitter.get_string_parser(content, "python")
  local root = lang_tree:parse()[1]:root()
  local query = vim.treesitter.query.parse("python", ts.query)
  local positions = {}
  for _, match, metadata in query:iter_matches(root, content, nil, nil, { all = false }) do
    local captured_nodes = {}
    for i, capture in ipairs(query.captures) do
      captured_nodes[capture] = match[i]
    end
    local pos = ts.build_position(file_path, content, captured_nodes)
    if pos then
      table.insert(positions, pos)
    end
  end
  return positions
end

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

  it("returns true for file with doctests but no tryke import", function()
    assert.is_true(ts.is_test_file(fixtures .. "lib_with_doctests.py"))
  end)
end)

describe("build_position", function()
  it("uses display_name from @test(name='...')", function()
    local positions = parse_positions(fixtures .. "display_name_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "test_basic" then
        assert.equal("basic equality", pos.name)
        found = true
      end
    end
    assert.is_true(found, "expected to find test_basic with display name")
  end)

  it("uses display_name from positional @test('...')", function()
    local positions = parse_positions(fixtures .. "display_name_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "test_positional" then
        assert.equal("positional name", pos.name)
        found = true
      end
    end
    assert.is_true(found, "expected to find test_positional with display name")
  end)

  it("uses function name when no display name", function()
    local positions = parse_positions(fixtures .. "display_name_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos.name == "test_bare" then
        assert.is_nil(pos._func_name)
        found = true
      end
    end
    assert.is_true(found, "expected to find test_bare with function name")
  end)

  it("uses function name for @test() without name arg", function()
    local positions = parse_positions(fixtures .. "display_name_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos.name == "test_no_name" then
        assert.is_nil(pos._func_name)
        found = true
      end
    end
    assert.is_true(found, "expected to find test_no_name with function name")
  end)
end)

describe("position_id", function()
  it("uses _func_name for id when display name is set", function()
    local id = ts.position_id(
      { path = "/project/tests/test.py", name = "basic equality", _func_name = "test_basic" },
      {}
    )
    assert.equal("/project/tests/test.py::test_basic", id)
  end)

  it("uses name for id when no display name", function()
    local id = ts.position_id(
      { path = "/project/tests/test.py", name = "test_bare" },
      {}
    )
    assert.equal("/project/tests/test.py::test_bare", id)
  end)

  it("uses _func_name from parents in id", function()
    local id = ts.position_id(
      { path = "/project/tests/test.py", name = "named test", _func_name = "test_fn" },
      { { name = "my group", _func_name = nil } }
    )
    assert.equal("/project/tests/test.py::my group::test_fn", id)
  end)

  it("skips doctest parents in id", function()
    local id = ts.position_id(
      { path = "/p/t.py", name = "doctest: Counter.increment", _func_name = "Counter.increment", _is_doctest = true },
      { { name = "doctest: Counter", _func_name = "Counter", _is_doctest = true } }
    )
    assert.equal("/p/t.py::Counter.increment", id)
  end)

  it("keeps namespace parents but skips doctest parents in id", function()
    local id = ts.position_id(
      { path = "/p/t.py", name = "doctest: add", _func_name = "add", _is_doctest = true },
      { { name = "expect" } }
    )
    assert.equal("/p/t.py::expect::add", id)
  end)
end)

describe("doctest discovery", function()
  it("discovers function with doctest", function()
    local positions = parse_positions(fixtures .. "doctest_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "add" then
        assert.equal("doctest: add", pos.name)
        assert.is_true(pos._is_doctest)
        found = true
      end
    end
    assert.is_true(found, "expected to find doctest for add()")
  end)

  it("does not discover function without doctest", function()
    local positions = parse_positions(fixtures .. "doctest_test.py")
    for _, pos in ipairs(positions) do
      assert.is_not_equal("no_doctest", pos._func_name)
      assert.is_not_equal("no_doctest", pos.name)
    end
  end)

  it("discovers class with doctest", function()
    local positions = parse_positions(fixtures .. "doctest_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "Counter" then
        assert.equal("doctest: Counter", pos.name)
        assert.is_true(pos._is_doctest)
        found = true
      end
    end
    assert.is_true(found, "expected to find doctest for Counter class")
  end)

  it("discovers method with dotted name", function()
    local positions = parse_positions(fixtures .. "doctest_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "Counter.increment" then
        assert.equal("doctest: Counter.increment", pos.name)
        assert.is_true(pos._is_doctest)
        found = true
      end
    end
    assert.is_true(found, "expected to find doctest for Counter.increment")
  end)

  it("does not discover method without doctest", function()
    local positions = parse_positions(fixtures .. "doctest_test.py")
    for _, pos in ipairs(positions) do
      if pos._func_name then
        assert.is_not_equal("Counter.reset", pos._func_name)
      end
    end
  end)

  it("discovers module-level doctest", function()
    local positions = parse_positions(fixtures .. "module_doctest.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "__module__" then
        assert.equal("doctest: (module)", pos.name)
        assert.is_true(pos._is_doctest)
        found = true
      end
    end
    assert.is_true(found, "expected to find module-level doctest")
  end)

  it("still discovers regular @test alongside doctests", function()
    local positions = parse_positions(fixtures .. "doctest_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos.name == "test_something" and not pos._is_doctest then
        found = true
      end
    end
    assert.is_true(found, "expected to find regular @test")
  end)

  it("discovers doctests in jc-news-style file (no tryke import)", function()
    local positions = parse_positions(fixtures .. "jc_news_init.py")
    local found_module = false
    local found_check_path = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "__module__" then
        assert.equal("doctest: (module)", pos.name)
        assert.is_true(pos._is_doctest)
        found_module = true
      end
      if pos._func_name == "_check_path" then
        assert.equal("doctest: _check_path", pos.name)
        assert.is_true(pos._is_doctest)
        found_check_path = true
      end
    end
    assert.is_true(found_module, "expected to find module-level doctest")
    assert.is_true(found_check_path, "expected to find _check_path doctest")
  end)

  it("discovers @test decorated function in simple test file", function()
    local positions = parse_positions(fixtures .. "simple_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "test_basic" then
        assert.equal("basic", pos.name)
        found = true
      end
    end
    assert.is_true(found, "expected to find test_basic with display name 'basic'")
  end)

  it("does not discover non-doctest functions in jc-news-style file", function()
    local positions = parse_positions(fixtures .. "jc_news_init.py")
    local bad_names = { "coro", "main", "async_run", "async_fetch_hn", "async_fetch_twitter",
      "async_summarize_hn", "async_summarize_twitter", "wrapper" }
    for _, pos in ipairs(positions) do
      for _, bad in ipairs(bad_names) do
        assert.is_not_equal(bad, pos._func_name, "should not discover " .. bad)
        assert.is_not_equal(bad, pos.name, "should not discover " .. bad)
      end
    end
  end)
end)

describe("build_position with @test.cases", function()
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


@test.cases(
    test.case("my test", n=0, expected=0),
    test.case("2 + 3", n=5, expected=25),
)
def square_typed(n: int, expected: int) -> None:
    expect(n * n).to_equal(expected)
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
      local res = ts.build_position("cases.py", src, captured_nodes)
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

  it("expands typed form test.case(...) into one position per case", function()
    local names = names_of(collect_positions(source))
    assert.is_true(vim.tbl_contains(names, "square_typed[my test]"))
    assert.is_true(vim.tbl_contains(names, "square_typed[2 + 3]"))
  end)

  it("does not emit a bare function position for @test.cases", function()
    local names = names_of(collect_positions(source))
    assert.is_false(vim.tbl_contains(names, "square"))
    assert.is_false(vim.tbl_contains(names, "add"))
    assert.is_false(vim.tbl_contains(names, "square_typed"))
  end)

  it("assigns each case its own range so siblings don't nest", function()
    -- When every case shared the decorator's range, neotest's nested_tests
    -- logic stacked them as parent→child→grandchild in the summary tree.
    local positions = collect_positions(source)
    local cases = {}
    for _, pos in ipairs(positions) do
      if pos.name:match("^square%[") or pos.name:match("^square_typed%[") or pos.name:match("^add%[") then
        table.insert(cases, pos)
      end
    end
    local seen = {}
    for _, pos in ipairs(cases) do
      local key = table.concat(pos.range, ",")
      assert.is_nil(seen[key], "cases share range " .. key .. " (would nest in neotest tree)")
      seen[key] = pos.name
    end
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

describe("import alias support", function()
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
      local res = ts.build_position("alias.py", src, captured_nodes)
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

  local function parse_fixture(name)
    local path = fixtures .. name
    local content = io.open(path, "r"):read("*a")
    return collect_positions(content)
  end

  local function names_of(positions)
    local names = {}
    for _, pos in ipairs(positions) do
      table.insert(names, pos.name)
    end
    return names
  end

  local function namespaces_of(positions)
    local names = {}
    for _, pos in ipairs(positions) do
      if pos.type == "namespace" then
        table.insert(names, pos.name)
      end
    end
    return names
  end

  it("recognises `@t.test` through a module alias", function()
    local names = names_of(parse_fixture("alias_module_test.py"))
    assert.is_true(vim.tbl_contains(names, "test_basic"))
  end)

  it("recognises `@t.test(name=...)` display names through a module alias", function()
    local positions = parse_fixture("alias_module_test.py")
    local found = false
    for _, pos in ipairs(positions) do
      if pos._func_name == "test_named" then
        assert.equal("named through module alias", pos.name)
        found = true
      end
    end
    assert.is_true(found, "expected display name from @t.test(name=...)")
  end)

  it("recognises `@t.test.skip(...)` through a module alias", function()
    local names = names_of(parse_fixture("alias_module_test.py"))
    assert.is_true(vim.tbl_contains(names, "test_skipped"))
  end)

  it("recognises `with t.describe(...)` through a module alias", function()
    local positions = parse_fixture("alias_module_test.py")
    assert.is_true(vim.tbl_contains(namespaces_of(positions), "Channel"))
  end)

  it("expands `@t.test.cases(...)` through a module alias", function()
    local names = names_of(parse_fixture("alias_module_test.py"))
    assert.is_true(vim.tbl_contains(names, "square[zero]"))
    assert.is_true(vim.tbl_contains(names, "square[one]"))
    assert.is_false(vim.tbl_contains(names, "square"))
  end)

  it("expands `@t.test.cases(t.test.case(...))` typed form", function()
    local names = names_of(parse_fixture("alias_module_test.py"))
    assert.is_true(vim.tbl_contains(names, "square_typed[my test]"))
    assert.is_true(vim.tbl_contains(names, "square_typed[2 + 3]"))
  end)

  it("recognises `@tst` through a symbol alias", function()
    local names = names_of(parse_fixture("alias_symbol_test.py"))
    assert.is_true(vim.tbl_contains(names, "fn"))
  end)

  it("recognises `@tst(name=...)` and positional forms through a symbol alias", function()
    local positions = parse_fixture("alias_symbol_test.py")
    local named, positional = false, false
    for _, pos in ipairs(positions) do
      if pos._func_name == "fn_named" then
        assert.equal("kwarg via alias", pos.name)
        named = true
      end
      if pos._func_name == "fn_positional" then
        assert.equal("positional via alias", pos.name)
        positional = true
      end
    end
    assert.is_true(named, "expected kwarg display name through alias")
    assert.is_true(positional, "expected positional display name through alias")
  end)

  it("recognises `@tst.skip` through a symbol alias", function()
    local names = names_of(parse_fixture("alias_symbol_test.py"))
    assert.is_true(vim.tbl_contains(names, "fn_skipped"))
  end)

  it("recognises `with d(...)` through a symbol alias", function()
    local positions = parse_fixture("alias_symbol_test.py")
    assert.is_true(vim.tbl_contains(namespaces_of(positions), "Group"))
  end)

  it("recognises `with d(name=...)` kwarg describe form", function()
    local positions = parse_fixture("alias_symbol_test.py")
    assert.is_true(vim.tbl_contains(namespaces_of(positions), "KwargGroup"))
  end)

  it("expands `@tst.cases(...)` through a symbol alias", function()
    local names = names_of(parse_fixture("alias_symbol_test.py"))
    assert.is_true(vim.tbl_contains(names, "parametrized[a]"))
    assert.is_true(vim.tbl_contains(names, "parametrized[b]"))
    assert.is_false(vim.tbl_contains(names, "parametrized"))
  end)

  it("expands typed `tst.case(...)` through a symbol alias", function()
    local names = names_of(parse_fixture("alias_symbol_test.py"))
    assert.is_true(vim.tbl_contains(names, "typed_cases[first]"))
    assert.is_true(vim.tbl_contains(names, "typed_cases[second]"))
  end)

  it("recognises aliases imported inside an `if __TRYKE_TESTING__:` guard", function()
    local positions = parse_fixture("alias_guard_test.py")
    assert.is_true(vim.tbl_contains(names_of(positions), "test_basic"))
    assert.is_true(vim.tbl_contains(namespaces_of(positions), "Channel"))
  end)

  it("does not discover tests when a local def shadows an aliased name", function()
    local names = names_of(parse_fixture("alias_shadow_test.py"))
    assert.is_false(vim.tbl_contains(names, "shadowed_not_a_tryke_test"))
  end)
end)
