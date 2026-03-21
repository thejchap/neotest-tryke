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
