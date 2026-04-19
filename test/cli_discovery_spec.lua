local cli = require("neotest-tryke.cli_discovery")

local function collect(tree)
  local out = {}
  for _, pos in tree:iter() do
    table.insert(out, pos)
  end
  return out
end

-- Replace `vim.system` for the duration of a test so we can feed the
-- parser canned stdout without actually spawning tryke. Restores the
-- original on teardown.
local function with_mock_system(stdout_lines, fn)
  local original = vim.system
  vim.system = function(_cmd, _opts)
    return {
      wait = function()
        return { code = 0, stdout = table.concat(stdout_lines, "\n"), stderr = "" }
      end,
    }
  end
  local ok, err = pcall(fn)
  vim.system = original
  if not ok then
    error(err)
  end
end

local function emit(tests)
  return vim.json.encode({ event = "collect_complete", tests = tests })
end

describe("cli_discovery", function()
  it("builds file > test for a single top-level test", function()
    local tree
    with_mock_system({ emit({
      { name = "test_addition", file_path = "tests/t.py", line_number = 4, groups = {} },
    }) }, function()
      tree = cli.discover("/proj/tests/t.py", "/proj", "tryke")
    end)
    local positions = collect(tree)
    assert.equal(2, #positions)
    assert.equal("file", positions[1].type)
    assert.equal("test", positions[2].type)
    assert.equal("/proj/tests/t.py::test_addition", positions[2].id)
    assert.equal("test_addition", positions[2].name)
  end)

  it("nests tests under a describe namespace", function()
    local tree
    with_mock_system({ emit({
      { name = "test_basic", file_path = "src/a.py", line_number = 16, groups = { "Channel" } },
    }) }, function()
      tree = cli.discover("/proj/src/a.py", "/proj", "tryke")
    end)
    local positions = collect(tree)
    assert.equal("file", positions[1].type)
    assert.equal("namespace", positions[2].type)
    assert.equal("Channel", positions[2].name)
    assert.equal("/proj/src/a.py::Channel", positions[2].id)
    assert.equal("test", positions[3].type)
    assert.equal("/proj/src/a.py::Channel::test_basic", positions[3].id)
  end)

  it("reuses the same namespace for siblings under the same describe", function()
    local tree
    with_mock_system({ emit({
      { name = "a", file_path = "t.py", line_number = 1, groups = { "Group" } },
      { name = "b", file_path = "t.py", line_number = 2, groups = { "Group" } },
    }) }, function()
      tree = cli.discover("/proj/t.py", "/proj", "tryke")
    end)
    local namespaces = 0
    for _, pos in ipairs(collect(tree)) do
      if pos.type == "namespace" then
        namespaces = namespaces + 1
      end
    end
    assert.equal(1, namespaces, "both tests should share one Group namespace")
  end)

  it("expands @test.cases into one position per case label", function()
    local tree
    with_mock_system({ emit({
      { name = "square", file_path = "t.py", line_number = 10, case_label = "zero", case_index = 0 },
      { name = "square", file_path = "t.py", line_number = 10, case_label = "one", case_index = 1 },
    }) }, function()
      tree = cli.discover("/proj/t.py", "/proj", "tryke")
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

  it("uses display_name as position name but keeps test.name on _func_name", function()
    local tree
    with_mock_system({ emit({
      { name = "test_basic", file_path = "t.py", line_number = 4, display_name = "basic equality" },
    }) }, function()
      tree = cli.discover("/proj/t.py", "/proj", "tryke")
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

  it("marks doctest positions with _is_doctest", function()
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
      tree = cli.discover("/proj/m.py", "/proj", "tryke")
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

  it("returns nil when tryke reports zero tests", function()
    local tree
    with_mock_system({ emit({}) }, function()
      tree = cli.discover("/proj/t.py", "/proj", "tryke")
    end)
    assert.is_nil(tree)
  end)
end)
