local M = {}

local sign_group = "neotest-tryke-assertions"
local sign_name = "neotest_passed"
local next_sign_id = 1
local placed_by_test = {}

local function absolute_path(root, path)
  if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then
    return path
  end
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(root, path)
  end
  return root:gsub("/+$", "") .. "/" .. path
end

local function clear_test(test_id)
  local placed = placed_by_test[test_id]
  if not placed then
    return
  end
  for _, sign_id in ipairs(placed.ids) do
    vim.fn.sign_unplace(sign_group, { buffer = placed.bufnr, id = sign_id })
  end
  placed_by_test[test_id] = nil
end

--- Place passing expectation signs for converted Tryke results.
---
--- Neotest's status consumer only places signs at discovered test positions;
--- assertion failures appear separately through its diagnostic consumer. This
--- small companion sign group fills the missing success case at the assertion
--- source lines, reusing Neotest's configured passed icon and highlight.
---@param converted table<string, table>
---@param root string
function M.render(converted, root)
  for test_id, result in pairs(converted) do
    clear_test(test_id)

    local lines = result._passed_assertion_lines or {}
    local file_path = result._file_path
    if #lines > 0 and type(file_path) == "string" and file_path ~= "" then
      local bufnr = vim.fn.bufnr(absolute_path(root, file_path))
      if bufnr >= 0 and vim.api.nvim_buf_is_valid(bufnr) and vim.fn.buflisted(bufnr) ~= 0 then
        local ids = {}
        for _, line in ipairs(lines) do
          local sign_id = next_sign_id
          next_sign_id = next_sign_id + 1
          local placed_id = vim.fn.sign_place(sign_id, sign_group, sign_name, bufnr, {
            lnum = line,
            priority = 999,
          })
          if placed_id and placed_id > 0 then
            table.insert(ids, sign_id)
          end
        end
        if #ids > 0 then
          placed_by_test[test_id] = { bufnr = bufnr, ids = ids }
        end
      end
    end

    -- These fields are adapter-internal transport for the renderer, not part
    -- of neotest.Result.
    result._passed_assertion_lines = nil
    result._file_path = nil
  end
end

return M
