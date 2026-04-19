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

  local position = {
    type = "test",
    path = file_path,
    range = { (test.line_number or 1) - 1, 0, (test.line_number or 1) - 1, 0 },
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
---@return table|nil
function M.discover(file_path, root, tryke_command)
  local rel = relpath(file_path, root)
  local cmd = { tryke_command, "test", rel, "--collect-only", "--reporter", "json" }
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
