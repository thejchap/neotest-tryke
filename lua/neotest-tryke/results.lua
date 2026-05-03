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

--- Build the test-level handle used to lead inline assertion diagnostics.
--- Mirrors cli_discovery.lua's position-name cascade so the diagnostic
--- text matches the test tree entry the user sees:
---   * `@test("name")` → display_name (composed with `[case_label]` for
---     parametrised cases).
---   * bare `@test.cases(...)` → function name (composed with
---     `[case_label]` for parametrised cases).
---   * plain `@test` → function name.
--- Returns nil only when neither display_name nor name is set, in which
--- case the caller falls back to the raw expression.
---@param test table
---@return string|nil
function M.diagnostic_lead(test)
  local has_display = type(test.display_name) == "string" and test.display_name ~= ""
  local has_case = type(test.case_label) == "string" and test.case_label ~= ""
  if has_display and has_case then
    return test.display_name .. "[" .. test.case_label .. "]"
  end
  if has_display then
    return test.display_name
  end
  if type(test.name) == "string" and test.name ~= "" then
    if has_case then
      return test.name .. "[" .. test.case_label .. "]"
    end
    return test.name
  end
  return nil
end

--- Best-effort recovery of the per-expectation label from the assertion
--- expression. Tryke's wire `Assertion` type carries only `expression`
--- (the literal source line) — the label is embedded in it — so we
--- pattern-match two common shapes:
---   1. `name="..."` / `name='...'` kwarg form (anywhere in the line).
---   2. `expect(<simple>, "...")` positional form, where `<simple>` is
---      any sequence not containing parens or commas. This covers
---      `expect(1, "label")`, `expect(x.y, "label")`,
---      `expect("s", "label")`, etc., but bails out when the first arg
---      itself has parens (e.g. `expect(f(x), "label")`) — extracting
---      that reliably needs a real parser.
--- Returns nil if neither shape matches.
---@param expression string|nil
---@return string|nil
function M.expect_label(expression)
  if type(expression) ~= "string" then
    return nil
  end
  local kwarg = expression:match('%f[%a]name%s*=%s*"([^"]*)"')
    or expression:match("%f[%a]name%s*=%s*'([^']*)'")
  if kwarg then
    return kwarg
  end
  return expression:match('expect%(%s*[^,()]-,%s*"([^"]*)"')
    or expression:match("expect%(%s*[^,()]-,%s*'([^']*)'")
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
      -- Lead the inline diagnostic with the test-level handle so it
      -- correlates with the test tree, then append the per-expectation
      -- `name=` label when set. The full expression is already on the
      -- annotated line, so duplicating it in the diagnostic only crowds
      -- the gutter and gets truncated on narrow screens.
      local test_lead = M.diagnostic_lead(tryke_result.test)
      for _, assertion in ipairs(detail.assertions) do
        local label = M.expect_label(assertion.expression)
        local prefix
        if test_lead and label then
          prefix = test_lead .. ": " .. label
        elseif test_lead then
          prefix = test_lead
        elseif label then
          prefix = label
        else
          prefix = assertion.expression or ""
        end
        table.insert(errors, {
          message = prefix
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
