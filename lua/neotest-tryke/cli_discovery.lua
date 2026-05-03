local M = {}

local Tree = require("neotest.types").Tree
local log = require("neotest-tryke.logger")

local function relpath(abs, root)
  if not root then
    return abs
  end
  if abs:sub(1, #root + 1) == root .. "/" then
    return abs:sub(#root + 2)
  end
  return abs
end

local function count_lines(path)
  local f = io.open(path, "r")
  if not f then
    return 0
  end
  local count = 0
  for _ in f:lines() do
    count = count + 1
  end
  f:close()
  return count
end

local source_cache = setmetatable({}, { __mode = "v" })

--- Read a file's lines once and cache the resulting array. Per-case line
--- resolution has to look at every case on the decorator, so reading the
--- file once up-front beats streaming it per case.
---@param path string
---@return string[]
local function read_lines(path)
  local cached = source_cache[path]
  if cached then
    return cached
  end
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  source_cache[path] = lines
  return lines
end

--- Patterns that identify the *origin line* of a single `@test.cases` case
--- inside a file. `test.case("label", …)` (typed form), `label=` (kwargs
--- form) and `("label", {…})` (list form) each leave a distinctive
--- substring on one line. We require the literal label string — with its
--- quotes, where applicable — so we don't false-positive on test bodies
--- that happen to mention the label somewhere below the decorator.
---@param label string
---@return string[]
local function case_line_patterns(label)
  -- Lua-pattern-escape the label so labels with magic chars (e.g.
  -- "2 + 3") still match literally.
  local escaped = label:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  return {
    'test%.case%("' .. escaped .. '"',
    "test%.case%('" .. escaped .. "'",
    '%("' .. escaped .. '"%s*,',
    "%('" .. escaped .. "'%s*,",
    "^%s*" .. escaped .. "%s*=",
  }
end

--- Locate the source line that declares the case whose label is *label*.
--- Anchor the search near *start_line* — the decorator's line range is
--- typically within a few dozen lines of the decorated function — so a
--- label that happens to appear in an unrelated test body further down
--- doesn't win. Falls back to `start_line` if nothing matches.
---@param file_path string
---@param label string
---@param start_line number
---@return number
local function find_case_line(file_path, label, start_line)
  local lines = read_lines(file_path)
  if #lines == 0 then
    return start_line
  end
  local patterns = case_line_patterns(label)
  local lo = math.max(1, start_line - 60)
  local hi = math.min(#lines, start_line + 120)
  local best
  for i = lo, hi do
    local line = lines[i]
    for _, pattern in ipairs(patterns) do
      if line:find(pattern) then
        if best == nil or math.abs(i - start_line) < math.abs(best - start_line) then
          best = i
        end
        break
      end
    end
  end
  return best or start_line
end

local function parse_collect_output(stdout)
  local tests = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and decoded and decoded.event == "collect_complete" and decoded.tests then
      for _, t in ipairs(decoded.tests) do
        table.insert(tests, t)
      end
    end
  end
  return tests
end

--- Return the leaf name that tryke uses for matching (`-k`) and for the
--- test-run result keys in `results.build_id`. For parametrized cases it
--- includes the `[label]` suffix; otherwise it's just `test.name`.
local function tryke_leaf(test)
  local label = test.case_label
  if type(label) == "string" and label ~= "" then
    return test.name .. "[" .. label .. "]"
  end
  return test.name
end

local function build_test_position(file_path, test)
  local leaf = tryke_leaf(test)
  local display = test.display_name
  local has_display = type(display) == "string" and display ~= "" and display ~= test.name

  -- For parametrized cases, `line_number` is the decorated function's line
  -- — every case for the same function would otherwise share it and the
  -- sign column would stack all their pass/fail markers on that one line.
  -- Scan the source for the exact `test.case("label", …)` / kwarg / tuple
  -- declaration so each case gets a per-line range.
  local line = test.line_number or 1
  if type(test.case_label) == "string" and test.case_label ~= "" then
    line = find_case_line(file_path, test.case_label, line)
  end

  local position = {
    type = "test",
    path = file_path,
    range = { line - 1, 0, line - 1, 0 },
  }

  if test.case_label and test.case_label ~= vim.NIL and test.case_label ~= "" then
    position.name = leaf
  elseif has_display then
    position.name = display
    position._func_name = test.name
  else
    position.name = test.name
  end

  if test.doctest_object and test.doctest_object ~= vim.NIL then
    position._is_doctest = true
    -- For doctests tryke sends a `"doctest: X"` display name; preserve it
    -- as the user-facing name and carry the dotted python symbol on
    -- `_func_name` so `-k` filtering lines up with the test runner.
    if type(display) == "string" and display ~= "" then
      position.name = display
      position._func_name = test.name
    end
  end

  return position
end

--- Construct the nested list that `Tree.from_list` expects: a file node
--- at the head, followed by namespace sublists containing child tests /
--- nested namespaces. Namespaces share the file's range so later
--- containment checks don't reject them — the Tree is built structurally
--- here, not by range contains, so the wide range is harmless.
local function build_tree_list(file_path, tests, file_range)
  local file_node = {
    {
      type = "file",
      path = file_path,
      name = vim.fn.fnamemodify(file_path, ":t"),
      range = file_range,
      id = file_path,
    },
  }

  -- Key namespaces by their full group path so we only create each one
  -- once even when tests arrive out of "tree order".
  local sep = "\0"
  local ns_lists = { [""] = file_node }

  for _, test in ipairs(tests) do
    local parent_list = file_node
    local groups = test.groups or {}
    local parent_key = ""
    local id_parts = { file_path }

    for _, group in ipairs(groups) do
      local new_key = parent_key == "" and group or (parent_key .. sep .. group)
      table.insert(id_parts, group)
      local existing = ns_lists[new_key]
      if not existing then
        existing = {
          {
            type = "namespace",
            path = file_path,
            name = group,
            range = file_range,
            id = table.concat(id_parts, "::"),
          },
        }
        table.insert(parent_list, existing)
        ns_lists[new_key] = existing
      end
      parent_list = existing
      parent_key = new_key
    end

    local position = build_test_position(file_path, test)
    local leaf_parts = vim.list_extend({}, id_parts)
    table.insert(leaf_parts, tryke_leaf(test))
    position.id = table.concat(leaf_parts, "::")
    table.insert(parent_list, { position })
  end

  return file_node
end

--- Discover tests in `file_path` by delegating to the tryke CLI.
--- Returns a `neotest.Tree` on success, or `nil` if tryke reports no
--- tests (lets neotest treat the file as empty).
---
--- Throws if tryke exits non-zero — the caller catches this and falls
--- back to the treesitter path so a missing binary doesn't take down
--- every discover_positions call.
---@param file_path string
---@param root string
---@param tryke_command string
---@param python string|nil  Forwarded as `--python <path>` so collection
---  uses the same interpreter as the test run; otherwise tryke falls back
---  to PATH and may not find the project's tryke package, breaking
---  discovery the same way it would break execution.
---@return table|nil
function M.discover(file_path, root, tryke_command, python)
  local rel = relpath(file_path, root)
  local cmd = { tryke_command, "test", rel, "--collect-only", "--reporter", "json" }
  if python then
    table.insert(cmd, "--python")
    table.insert(cmd, python)
  end
  log.debug("cli_discover: spawn", table.concat(cmd, " "), "cwd =", root)
  local ok, result = pcall(function()
    return vim.system(cmd, { cwd = root, text = true }):wait()
  end)
  if not ok then
    log.error("cli_discover: vim.system threw for", tryke_command, "—", tostring(result))
    error("failed to run " .. tryke_command .. ": " .. tostring(result))
  end
  if result.code ~= 0 then
    log.warn(
      "cli_discover: exit",
      result.code,
      "for",
      file_path,
      "stderr:",
      (result.stderr or ""):sub(1, 500)
    )
    error("tryke --collect-only exited " .. result.code)
  end
  local tests = parse_collect_output(result.stdout)
  log.debug("cli_discover:", file_path, "→", #tests, "test(s)")
  if #tests == 0 then
    return nil
  end
  for _, t in ipairs(tests) do
    log.trace(
      "cli_discover: test name =",
      t.name,
      "groups =",
      t.groups,
      "case_label =",
      t.case_label,
      "line =",
      t.line_number
    )
  end
  local file_range = { 0, 0, count_lines(file_path), 0 }
  local list = build_tree_list(file_path, tests, file_range)
  return Tree.from_list(list, function(pos)
    return pos.id
  end)
end

return M
