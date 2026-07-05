local assertion_signs = require("neotest-tryke.assertion_signs")

describe("assertion signs", function()
  local root = vim.fn.getcwd()
  local relative_path = "test/fixtures/tryke_test.py"
  local bufnr

  before_each(function()
    vim.fn.sign_define("neotest_passed", { text = "✓", texthl = "NeotestPassed" })
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/" .. relative_path))
    bufnr = vim.api.nvim_get_current_buf()
  end)

  after_each(function()
    vim.fn.sign_unplace("neotest-tryke-assertions", { buffer = bufnr })
    vim.cmd("bwipeout!")
    vim.fn.sign_undefine("neotest_passed")
  end)

  it("places passed signs and replaces stale signs for a test", function()
    local converted = {
      ["test-id"] = {
        _passed_assertion_lines = { 5, 6 },
        _file_path = relative_path,
      },
    }

    assertion_signs.render(converted, root)

    local placed = vim.fn.sign_getplaced(bufnr, { group = "neotest-tryke-assertions" })
    assert.equal(2, #placed[1].signs)
    assert.same({ 5, 6 }, vim.tbl_map(function(sign)
      return sign.lnum
    end, placed[1].signs))
    assert.is_nil(converted["test-id"]._passed_assertion_lines)
    assert.is_nil(converted["test-id"]._file_path)

    assertion_signs.render({
      ["test-id"] = {
        _passed_assertion_lines = {},
        _file_path = relative_path,
      },
    }, root)

    placed = vim.fn.sign_getplaced(bufnr, { group = "neotest-tryke-assertions" })
    assert.equal(0, #placed[1].signs)
  end)
end)
