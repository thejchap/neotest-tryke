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
end)
