local M = {}

local status_map = {
  passed = "passed",
  failed = "failed",
  skipped = "skipped",
  error = "failed",
  x_failed = "passed",
  x_passed = "failed",
  todo = "skipped",
}

function M.convert_result(tryke_result)
  local outcome = tryke_result.outcome
  local neotest_status = status_map[outcome.status] or "failed"

  local short = tryke_result.test.name .. ": " .. neotest_status

  local result = {
    status = neotest_status,
    short = short,
  }

  if neotest_status == "failed" then
    local errors = {}
    local detail = outcome.detail

    if detail and detail.assertions and #detail.assertions > 0 then
      for _, assertion in ipairs(detail.assertions) do
        table.insert(errors, {
          message = assertion.expression .. ": expected " .. assertion.expected .. ", received " .. assertion.received,
          line = assertion.line - 1,
        })
      end
    elseif detail and detail.message and detail.message ~= "" then
      table.insert(errors, { message = detail.message })
    end

    if #errors > 0 then
      result.errors = errors
    end
  end

  return result
end

function M.parse_output(output_content, root_path)
  local results = {}
  local stripped_root = root_path:gsub("/+$", "")

  local joinpath = vim.fs and vim.fs.joinpath or function(a, b)
    return a .. "/" .. b
  end

  for line in output_content:gmatch("[^\n]+") do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and decoded and decoded.event == "test_complete" and decoded.result then
      local tryke_result = decoded.result
      local test = tryke_result.test
      if test.file_path then
        local file = joinpath(stripped_root, test.file_path)
        local id = file .. "::" .. test.name
        results[id] = M.convert_result(tryke_result)
      end
    end
  end

  return results
end

return M
