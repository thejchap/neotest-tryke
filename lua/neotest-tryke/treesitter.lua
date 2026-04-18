local alias = require("neotest-tryke.alias")

local M = {}

--- TreeSitter query matching every shape the build_position callback needs
--- to reason about. The matchers are intentionally broad: decorators of any
--- kind, context-managed calls of any kind, plus doctest shapes. Lua-side
--- logic in `build_position` resolves each match against the per-file
--- alias table built by `alias.lua`, so aliased imports
--- (`import tryke as t`, `from tryke import test as tst`, etc.) are
--- recognised without having to duplicate each pattern.
M.query = [[
  ;; with <anything>(...):
  (with_statement
    (with_clause
      (with_item
        value: (call) @_ns_call))) @namespace.definition

  ;; Any decorated function definition. Lua walks the decorator stack to
  ;; decide whether any decorator resolves to a tryke test marker.
  (decorated_definition
    definition: (function_definition
      name: (identifier) @test.name)) @test.definition

  ;; doctest in function/method docstring
  (function_definition
    name: (identifier) @test.name
    body: (block .
      (expression_statement
        (string
          (string_content) @_docstring)))) @test.definition
  (#match? @_docstring ">>>")

  ;; doctest in class docstring
  (class_definition
    name: (identifier) @test.name
    body: (block .
      (expression_statement
        (string
          (string_content) @_docstring)))) @test.definition
  (#match? @_docstring ">>>")

  ;; doctest in module-level docstring
  (module .
    (expression_statement
      (string
        (string_content) @_module_docstring)) @test.definition)
  (#match? @_module_docstring ">>>")
]]

local MODIFIER_ATTRS = {
  skip = true,
  todo = true,
  xfail = true,
  skip_if = true,
}

local function get_string_content(string_node, source)
  for i = 0, string_node:named_child_count() - 1 do
    local child = string_node:named_child(i)
    if child:type() == "string_content" then
      return vim.treesitter.get_node_text(child, source)
    end
  end
  return nil
end

--- Extract the first positional or `name=` string argument from *call_node*.
--- Used to resolve `@test("…")` / `@test(name="…")` display names and
--- `describe("…")` / `describe(name="…")` namespace labels.
---@param call_node table
---@param source string
---@return string|nil
local function extract_string_arg(call_node, source)
  local args_node
  for i = 0, call_node:named_child_count() - 1 do
    local c = call_node:named_child(i)
    if c:type() == "argument_list" then
      args_node = c
      break
    end
  end
  if not args_node then
    return nil
  end
  for i = 0, args_node:named_child_count() - 1 do
    local arg = args_node:named_child(i)
    if arg:type() == "keyword_argument" then
      local key = arg:named_child(0)
      if key and vim.treesitter.get_node_text(key, source) == "name" then
        local val = arg:named_child(1)
        if val and val:type() == "string" then
          return get_string_content(val, source)
        end
      end
    end
  end
  local first = args_node:named_child(0)
  if first and first:type() == "string" then
    return get_string_content(first, source)
  end
  return nil
end

--- Describes a decorator's relationship to tryke. `kind` names the role —
--- `test` for `@test` / `@t.test` / `@tst`, `modifier` for `@test.skip` and
--- friends, `cases` for `@test.cases(...)`. `call` holds the outer call
--- node when the decorator is invoked with parentheses so the caller can
--- pull display names or case tables out of the same node.
---@alias DecoratorInfo { kind: "test"|"modifier"|"cases", attr: string|nil, call: table|nil }

--- Classify a decorator node (the `(decorator ...)` AST node) against the
--- per-file alias table. Returns `nil` when the decorator is not a tryke
--- marker — for example a `@staticmethod` or unrelated `@mylib.decorator`.
---@param decorator_node table
---@param source string
---@param aliases table
---@return DecoratorInfo|nil
local function classify_decorator(decorator_node, source, aliases)
  local expr
  for i = 0, decorator_node:named_child_count() - 1 do
    expr = decorator_node:named_child(i)
    break
  end
  if not expr then
    return nil
  end

  local call_node = nil
  if expr:type() == "call" then
    call_node = expr
    local inner
    for i = 0, expr:named_child_count() - 1 do
      local c = expr:named_child(i)
      if c:type() ~= "argument_list" then
        inner = c
        break
      end
    end
    if not inner then
      return nil
    end
    expr = inner
  end

  if expr:type() == "identifier" then
    local name = vim.treesitter.get_node_text(expr, source)
    if alias.is_tryke_symbol(aliases, source, name, "test") then
      return { kind = "test", call = call_node }
    end
    return nil
  end

  if expr:type() ~= "attribute" then
    return nil
  end

  local obj = expr:named_child(0)
  local attr = expr:named_child(1)
  if not obj or not attr then
    return nil
  end
  local attr_name = vim.treesitter.get_node_text(attr, source)

  if obj:type() == "identifier" then
    local obj_name = vim.treesitter.get_node_text(obj, source)

    if attr_name == "test" and alias.is_module(aliases, obj_name) then
      return { kind = "test", call = call_node }
    end

    if attr_name == "cases" and alias.is_tryke_symbol(aliases, source, obj_name, "test") then
      if call_node then
        return { kind = "cases", call = call_node }
      end
      return nil
    end

    if MODIFIER_ATTRS[attr_name] and alias.is_tryke_symbol(aliases, source, obj_name, "test") then
      return { kind = "modifier", attr = attr_name, call = call_node }
    end

    return nil
  end

  if obj:type() == "attribute" then
    local inner_obj = obj:named_child(0)
    local inner_attr = obj:named_child(1)
    if not inner_obj or not inner_attr or inner_obj:type() ~= "identifier" then
      return nil
    end
    local mod_name = vim.treesitter.get_node_text(inner_obj, source)
    local mid_attr = vim.treesitter.get_node_text(inner_attr, source)
    if mid_attr ~= "test" or not alias.is_module(aliases, mod_name) then
      return nil
    end
    if attr_name == "cases" then
      if call_node then
        return { kind = "cases", call = call_node }
      end
      return nil
    end
    if MODIFIER_ATTRS[attr_name] then
      return { kind = "modifier", attr = attr_name, call = call_node }
    end
    return nil
  end

  return nil
end

--- Collect every tryke decorator on a `decorated_definition` node, in the
--- order they appear in source. The returned list is used to find the
--- first meaningful decorator (for display names) and to detect the
--- common `@test.skip` + `@test.cases` stacking pattern.
---@param def_node table
---@param source string
---@param aliases table
---@return DecoratorInfo[]
local function collect_tryke_decorators(def_node, source, aliases)
  local out = {}
  for i = 0, def_node:named_child_count() - 1 do
    local child = def_node:named_child(i)
    if child:type() == "decorator" then
      local info = classify_decorator(child, source, aliases)
      if info then
        table.insert(out, info)
      end
    end
  end
  return out
end

--- Walk upward from a doctest definition node to the enclosing class, if
--- any. Tryke addresses class doctests with flat dotted names
--- (`Counter.increment`), so the plugin flattens the same way.
---@param node table
---@param source string
---@return string|nil
local function find_parent_class_name(node, source)
  local parent = node:parent()
  if parent and parent:type() == "block" then
    local grandparent = parent:parent()
    if grandparent and grandparent:type() == "class_definition" then
      for i = 0, grandparent:named_child_count() - 1 do
        local c = grandparent:named_child(i)
        if c:type() == "identifier" then
          return vim.treesitter.get_node_text(c, source)
        end
      end
    end
  end
  return nil
end

--- Does the expression `expr` look like a `test.case(...)` call, where
--- the test name is either a direct tryke alias or reached via a module
--- alias (e.g., `t.test.case(...)`)?
---@param expr table
---@param source string
---@param aliases table
---@return boolean
local function is_test_case_call(expr, source, aliases)
  if expr:type() ~= "call" then
    return false
  end
  local fn
  for i = 0, expr:named_child_count() - 1 do
    local c = expr:named_child(i)
    if c:type() ~= "argument_list" then
      fn = c
      break
    end
  end
  if not fn or fn:type() ~= "attribute" then
    return false
  end
  local obj = fn:named_child(0)
  local attr = fn:named_child(1)
  if not obj or not attr then
    return false
  end
  if vim.treesitter.get_node_text(attr, source) ~= "case" then
    return false
  end
  if obj:type() == "identifier" then
    local name = vim.treesitter.get_node_text(obj, source)
    return alias.is_tryke_symbol(aliases, source, name, "test")
  end
  if obj:type() == "attribute" then
    local inner_obj = obj:named_child(0)
    local inner_attr = obj:named_child(1)
    if not inner_obj or not inner_attr or inner_obj:type() ~= "identifier" then
      return false
    end
    local mod_name = vim.treesitter.get_node_text(inner_obj, source)
    local mid_attr = vim.treesitter.get_node_text(inner_attr, source)
    return mid_attr == "test" and alias.is_module(aliases, mod_name)
  end
  return false
end

--- Expand the arguments of a `@test.cases(...)` call into one position
--- per enumerable case. Mirrors the three shapes the tryke discoverer
--- accepts:
---   * kwargs:  `@test.cases(zero={...}, one={...})`
---   * list:    `@test.cases([("label", {...}), ...])`
---   * typed:   `@test.cases(test.case("label", ...), ...)` — also
---              recognised through module / symbol aliases so
---              `t.test.case("label", ...)` and
---              `tst.case("label", ...)` yield cases.
--- Returns nil when no enumerable cases are detected, letting the caller
--- fall back to a bare function position.
---@param cases_call table
---@param func_name string
---@param file_path string
---@param source string
---@param aliases table
---@return table[]|nil
local function expand_cases(cases_call, func_name, file_path, source, aliases)
  local args_node
  for i = 0, cases_call:named_child_count() - 1 do
    local c = cases_call:named_child(i)
    if c:type() == "argument_list" then
      args_node = c
      break
    end
  end
  if not args_node then
    return nil
  end

  local positions = {}

  for i = 0, args_node:named_child_count() - 1 do
    local child = args_node:named_child(i)
    if child then
      local ctype = child:type()
      if ctype == "keyword_argument" then
        local name_node = child:named_child(0)
        if name_node and name_node:type() == "identifier" then
          local label = vim.treesitter.get_node_text(name_node, source)
          table.insert(positions, {
            type = "test",
            path = file_path,
            name = func_name .. "[" .. label .. "]",
            range = { child:range() },
          })
        end
      elseif ctype == "list" then
        for j = 0, child:named_child_count() - 1 do
          local elem = child:named_child(j)
          if elem and elem:type() == "tuple" and elem:named_child_count() >= 1 then
            local first = elem:named_child(0)
            if first and first:type() == "string" then
              local label = get_string_content(first, source)
              if label then
                table.insert(positions, {
                  type = "test",
                  path = file_path,
                  name = func_name .. "[" .. label .. "]",
                  range = { elem:range() },
                })
              end
            end
          end
        end
      elseif ctype == "call" and is_test_case_call(child, source, aliases) then
        local call_args
        for k = 0, child:named_child_count() - 1 do
          local c = child:named_child(k)
          if c and c:type() == "argument_list" then
            call_args = c
            break
          end
        end
        if call_args and call_args:named_child_count() >= 1 then
          local first = call_args:named_child(0)
          if first and first:type() == "string" then
            local label = get_string_content(first, source)
            if label then
              table.insert(positions, {
                type = "test",
                path = file_path,
                name = func_name .. "[" .. label .. "]",
                range = { child:range() },
              })
            end
          end
        end
      end
    end
  end

  if #positions > 0 then
    return positions
  end
  return nil
end

--- Inspect a `with <call>(…):` to decide whether the call targets tryke's
--- `describe`, either directly (`describe(...)`, via symbol alias), or
--- through a module alias (`tryke.describe(...)` / `t.describe(...)`).
--- Returns the string name used by tryke for that describe block or nil
--- when the call is some other context manager.
---@param call_node table
---@param source string
---@param aliases table
---@return string|nil
local function extract_describe_name(call_node, source, aliases)
  local fn
  for i = 0, call_node:named_child_count() - 1 do
    local c = call_node:named_child(i)
    if c:type() ~= "argument_list" then
      fn = c
      break
    end
  end
  if not fn then
    return nil
  end
  local is_describe = false
  if fn:type() == "identifier" then
    local name = vim.treesitter.get_node_text(fn, source)
    is_describe = alias.is_tryke_symbol(aliases, source, name, "describe")
  elseif fn:type() == "attribute" then
    local obj = fn:named_child(0)
    local attr = fn:named_child(1)
    if obj and attr and obj:type() == "identifier" then
      local obj_name = vim.treesitter.get_node_text(obj, source)
      local attr_name = vim.treesitter.get_node_text(attr, source)
      is_describe = attr_name == "describe" and alias.is_module(aliases, obj_name)
    end
  end
  if not is_describe then
    return nil
  end
  return extract_string_arg(call_node, source)
end

--- Build neotest positions from a query match. Routes matches by the
--- shape of the captured definition node — module / function / class
--- doctests, decorated functions, or `with describe(...)` namespaces —
--- and defers tryke-specific recognition to the alias-aware helpers
--- above so aliased imports are handled without duplicating patterns.
---@param file_path string
---@param source string
---@param captured_nodes table<string, table>
---@return table|table[]|nil
function M.build_position(file_path, source, captured_nodes)
  local aliases = alias.get(source)

  if captured_nodes["_module_docstring"] then
    local docstring_text = vim.treesitter.get_node_text(captured_nodes["_module_docstring"], source)
    if not docstring_text or not docstring_text:find(">>>") then
      return nil
    end
    local definition = captured_nodes["test.definition"]
    return {
      type = "test",
      path = file_path,
      name = "doctest: (module)",
      _func_name = "__module__",
      _is_doctest = true,
      range = { definition:range() },
    }
  end

  if captured_nodes["_docstring"] then
    local docstring_text = vim.treesitter.get_node_text(captured_nodes["_docstring"], source)
    if not docstring_text or not docstring_text:find(">>>") then
      return nil
    end
    local name_node = captured_nodes["test.name"]
    local definition = captured_nodes["test.definition"]
    if not name_node or not definition then
      return nil
    end
    local name = vim.treesitter.get_node_text(name_node, source)
    local doctest_name = name
    local class_name = find_parent_class_name(definition, source)
    if class_name then
      doctest_name = class_name .. "." .. name
    end
    return {
      type = "test",
      path = file_path,
      name = "doctest: " .. doctest_name,
      _func_name = doctest_name,
      _is_doctest = true,
      range = { definition:range() },
    }
  end

  if captured_nodes["_ns_call"] then
    local name = extract_describe_name(captured_nodes["_ns_call"], source, aliases)
    if not name then
      return nil
    end
    local definition = captured_nodes["namespace.definition"]
    return {
      type = "namespace",
      path = file_path,
      name = name,
      range = { definition:range() },
    }
  end

  local test_def_node = captured_nodes["test.definition"]
  local test_name_node = captured_nodes["test.name"]
  if not test_def_node or not test_name_node then
    return nil
  end
  if test_def_node:type() ~= "decorated_definition" then
    return nil
  end

  local decorators = collect_tryke_decorators(test_def_node, source, aliases)
  if #decorators == 0 then
    return nil
  end

  local func_name = vim.treesitter.get_node_text(test_name_node, source)

  local cases_info
  local test_info
  for _, info in ipairs(decorators) do
    if info.kind == "cases" and not cases_info then
      cases_info = info
    elseif info.kind == "test" and not test_info then
      test_info = info
    end
  end

  if cases_info then
    local expanded = expand_cases(cases_info.call, func_name, file_path, source, aliases)
    if expanded then
      return expanded
    end
    return {
      type = "test",
      path = file_path,
      name = func_name,
      range = { test_def_node:range() },
    }
  end

  local decorator = test_info or decorators[1]
  local position = {
    type = "test",
    path = file_path,
    name = func_name,
    range = { test_def_node:range() },
  }
  -- Only `@test(...)` style decorators can supply a display name — modifier
  -- decorators like `@test.skip("reason")` take a reason string, not a name.
  if decorator.kind == "test" and decorator.call then
    local display_name = extract_string_arg(decorator.call, source)
    if display_name then
      position.name = display_name
      position._func_name = func_name
    end
  end
  return position
end

function M.position_id(position, parents)
  local parent_names = {}
  for _, pos in ipairs(parents) do
    if not pos._is_doctest then
      table.insert(parent_names, pos._func_name or pos.name)
    end
  end
  return table.concat(
    vim.tbl_flatten({
      position.path,
      parent_names,
      position._func_name or position.name,
    }),
    "::"
  )
end

function M.is_test_file(file_path)
  if not vim.endswith(file_path, ".py") then
    return false
  end
  local f = io.open(file_path, "r")
  if not f then
    return false
  end
  local has_tryke_import = false
  local has_doctest = false
  local i = 0
  for line in f:lines() do
    i = i + 1
    if i <= 50 and (line:find("from tryke import") or line:find("import tryke")) then
      has_tryke_import = true
      break
    end
    if not has_doctest and line:find(">>>") then
      has_doctest = true
    end
  end
  f:close()
  return has_tryke_import or has_doctest
end

function M.is_tryke_project(root)
  local f = io.open(root .. "/pyproject.toml", "r")
  if not f then
    return false
  end
  local content = f:read("*a")
  f:close()
  return content:find("tryke") ~= nil
end

return M
