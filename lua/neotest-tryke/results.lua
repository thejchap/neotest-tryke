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

--- Pull the line number of the last user-frame in a Python traceback that
--- targets the same source file as the failing test. Tracebacks lead with
--- worker.py frames and end with the user's call site, so iterating to the
--- last match gives the line where the exception actually fired. Match by
--- suffix because traceback frames carry absolute paths but `file_path` is
--- root-relative.
---@param traceback string
---@param file_path string
---@return number|nil
local function user_frame_line(traceback, file_path)
  if type(traceback) ~= "string" or type(file_path) ~= "string" or file_path == "" then
    return nil
  end
  local last
  for path, lnum in traceback:gmatch('File "([^"]+)", line (%d+)') do
    if path == file_path or path:sub(-#file_path - 1) == "/" .. file_path then
      last = tonumber(lnum)
    end
  end
  return last
end

function M.build_id(root, test)
  local joinpath = vim.fs and vim.fs.joinpath or function(a, b)
    return a .. "/" .. b
  end
  local file = joinpath(root, test.file_path)
  local parts = { file }
  if test.groups then
    for _, group in ipairs(test.groups) do
      table.insert(parts, group)
    end
  end
  local leaf = test.name
  if test.case_label and test.case_label ~= vim.NIL and test.case_label ~= "" then
    leaf = leaf .. "[" .. test.case_label .. "]"
  end
  table.insert(parts, leaf)
  return table.concat(parts, "::")
end

function M.convert_result(tryke_result)
  local outcome = tryke_result.outcome
  local neotest_status = status_map[outcome.status] or "failed"

  local display = type(tryke_result.test.display_name) == "string"
      and tryke_result.test.display_name
    or tryke_result.test.name
  local short = display .. ": " .. neotest_status

  local result = {
    status = neotest_status,
    short = short,
  }

  if neotest_status == "failed" then
    local errors = {}
    local detail = outcome.detail

    if detail and detail.assertions and #detail.assertions > 0 then
      -- Lead the inline diagnostic with the test's display name when
      -- present so users can correlate the failure with the test tree
      -- entry. The full assertion expression is on the line being
      -- annotated, so repeating it inside the diagnostic only crowds
      -- the gutter. For tests without a display name (no `@test("name")`
      -- and no docstring), fall back to the expression — there's no
      -- more identifying label to lead with.
      local has_display = type(tryke_result.test.display_name) == "string"
        and tryke_result.test.display_name ~= ""
      local lead_default = has_display and tryke_result.test.display_name or nil
      for _, assertion in ipairs(detail.assertions) do
        local lead = lead_default or assertion.expression
        table.insert(errors, {
          message = lead
            .. ": expected "
            .. assertion.expected
            .. ", received "
            .. assertion.received,
          line = assertion.line - 1,
        })
      end
    elseif detail then
      -- Exception-style failures: lead with the concise `message` (e.g.
      -- "KeyError: 'x'") so the inline diagnostic stays readable, then
      -- append the full Python traceback when emitted so hover/expand
      -- shows where the exception actually fired. Pull the line number
      -- from the last user-frame in the traceback so the diagnostic
      -- pins to the failing line, not the test definition.
      local message
      if type(detail.message) == "string" and detail.message ~= "" then
        message = detail.message
        if type(detail.traceback) == "string" and detail.traceback ~= "" then
          message = message .. "\n\n" .. detail.traceback
        end
      elseif type(detail.traceback) == "string" and detail.traceback ~= "" then
        message = detail.traceback
      end
      if message then
        local err = { message = message }
        local file_path = tryke_result.test and tryke_result.test.file_path
        if
          type(detail.traceback) == "string"
          and detail.traceback ~= ""
          and type(file_path) == "string"
        then
          local lnum = user_frame_line(detail.traceback, file_path)
          if lnum then
            err.line = lnum - 1
          end
        end
        table.insert(errors, err)
      end
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

  for line in output_content:gmatch("[^\n]+") do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and decoded and decoded.event == "test_complete" and decoded.result then
      local tryke_result = decoded.result
      local test = tryke_result.test
      if test.file_path then
        local id = M.build_id(stripped_root, test)
        results[id] = M.convert_result(tryke_result)
      end
    end
  end

  return results
end

return M
