local M = {}

M.query = [[
  ;; with describe("name"):
  (with_statement
    (with_clause
      (with_item
        value: (call
          function: (identifier) @_ns_fn
          arguments: (argument_list
            (string
              (string_content) @namespace.name)))))
  ) @namespace.definition
  (#eq? @_ns_fn "describe")

  ;; @test
  (decorated_definition
    (decorator (identifier) @_dec_name)
    definition: (function_definition
      name: (identifier) @test.name)) @test.definition
  (#eq? @_dec_name "test")

  ;; @test() / @test(name="...")
  (decorated_definition
    (decorator (call
      function: (identifier) @_dec_name))
    definition: (function_definition
      name: (identifier) @test.name)) @test.definition
  (#eq? @_dec_name "test")

  ;; @test.skip / @test.todo / @test.xfail
  (decorated_definition
    (decorator (attribute
      object: (identifier) @_dec_obj))
    definition: (function_definition
      name: (identifier) @test.name)) @test.definition
  (#eq? @_dec_obj "test")

  ;; @test.skip(...) / @test.todo(...) / @test.xfail(...) / @test.skip_if(...)
  ;; (not @test.cases — handled by the dedicated cases pattern below)
  ((decorated_definition
    (decorator (call
      function: (attribute
        object: (identifier) @_dec_obj
        attribute: (identifier) @_dec_attr)))
    definition: (function_definition
      name: (identifier) @test.name)) @test.definition
   (#eq? @_dec_obj "test")
   (#not-eq? @_dec_attr "cases"))

  ;; @test.cases(...) — build_position expands into one position per case
  ((decorated_definition
    (decorator (call
      function: (attribute
        object: (identifier) @_cases_obj
        attribute: (identifier) @_cases_attr)
      arguments: (argument_list) @_cases_args))
    definition: (function_definition
      name: (identifier) @test.name)) @test.definition
   (#eq? @_cases_obj "test")
   (#eq? @_cases_attr "cases"))

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

local function get_string_content(string_node, source)
  for i = 0, string_node:named_child_count() - 1 do
    local child = string_node:named_child(i)
    if child:type() == "string_content" then
      return vim.treesitter.get_node_text(child, source)
    end
  end
  return nil
end

local function extract_display_name(definition_node, source)
  for i = 0, definition_node:named_child_count() - 1 do
    local child = definition_node:named_child(i)
    if child:type() == "decorator" then
      for j = 0, child:named_child_count() - 1 do
        local dec_child = child:named_child(j)
        if dec_child:type() == "call" then
          local args_node = nil
          for k = 0, dec_child:named_child_count() - 1 do
            local c = dec_child:named_child(k)
            if c:type() == "argument_list" then
              args_node = c
              break
            end
          end
          if not args_node then
            return nil
          end
          -- Keyword form: @test(name="...").
          for l = 0, args_node:named_child_count() - 1 do
            local arg = args_node:named_child(l)
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
          -- Positional form: @test("...").
          local first = args_node:named_child(0)
          if first and first:type() == "string" then
            return get_string_content(first, source)
          end
          return nil
        end
      end
    end
  end
  return nil
end

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

--- Return true if *decorated_definition_node* has a `@test.cases(...)`
--- decorator among its children. Used to suppress generic `@test.*`
--- matches when a `@test.cases` decorator is stacked on the same function:
--- the cases pattern owns the expansion, so the generic pattern would
--- otherwise register a redundant bare-function position.
---@param decorated_definition_node TSNode
---@param source string
---@return boolean
local function has_cases_decorator(decorated_definition_node, source)
  for i = 0, decorated_definition_node:named_child_count() - 1 do
    local child = decorated_definition_node:named_child(i)
    if child and child:type() == "decorator" then
      local inner = child:named_child(0)
      if inner and inner:type() == "call" then
        local fn = inner:named_child(0)
        if fn and fn:type() == "attribute" then
          local obj = fn:named_child(0)
          local attr = fn:named_child(1)
          if
            obj
            and attr
            and vim.treesitter.get_node_text(obj, source) == "test"
            and vim.treesitter.get_node_text(attr, source) == "cases"
          then
            return true
          end
        end
      end
    end
  end
  return false
end

--- Expand a `@test.cases(...)` match into one position per case label.
--- Returns nil when the argument list has no enumerable cases (e.g. the
--- decorator argument is a non-literal expression), letting the caller
--- fall back to a bare function position.
---
--- Each case gets the range of its own argument node (not the shared
--- decorated-definition range). Neotest nests positions by range
--- containment when `nested_tests = true`; giving every case the same
--- range causes them to stack as parent→child→grandchild instead of
--- rendering as siblings.
---@param cases_args TSNode
---@param func_name string
---@param file_path string
---@param source string
---@return table[]|nil
local function expand_cases(cases_args, func_name, file_path, source)
  local positions = {}

  for i = 0, cases_args:named_child_count() - 1 do
    local child = cases_args:named_child(i)
    if child then
      local ctype = child:type()
      if ctype == "keyword_argument" then
        -- Kwargs form: `@test.cases(zero={...}, one={...})`.
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
        -- List form: `@test.cases([("2 + 3", {...}), ...])`.
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
      elseif ctype == "call" then
        -- Typed form: `@test.cases(test.case("my test", n=0, expected=0), ...)`.
        -- Each positional argument is a `test.case(label, **kwargs)` call whose
        -- first argument is a string literal label.
        local fn = child:named_child(0)
        if fn and fn:type() == "attribute" then
          local obj = fn:named_child(0)
          local attr = fn:named_child(1)
          if
            obj
            and attr
            and vim.treesitter.get_node_text(obj, source) == "test"
            and vim.treesitter.get_node_text(attr, source) == "case"
          then
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
    end
  end

  if #positions > 0 then
    return positions
  end
  return nil
end

--- Build neotest positions from a query match. Handles `@test.cases` by
--- expanding one decorated function into one position per case label; class
--- and function doctests by flattening class-qualified names; and the
--- `@test(name="...")` display-name form by attaching `_func_name`.
---@param file_path string
---@param source string
---@param captured_nodes table<string, TSNode>
---@return table|table[]|nil
function M.build_position(file_path, source, captured_nodes)
  -- Module-level doctest (no test.name capture).
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

  -- Verify decorator patterns actually matched @test (treesitter predicates
  -- may not be enforced in all environments, so check captured decorator
  -- name in lua as a safety net).
  if captured_nodes["_dec_name"] then
    local dec_text = vim.treesitter.get_node_text(captured_nodes["_dec_name"], source)
    if dec_text ~= "test" then
      return nil
    end
  end
  if captured_nodes["_dec_obj"] then
    local dec_text = vim.treesitter.get_node_text(captured_nodes["_dec_obj"], source)
    if dec_text ~= "test" then
      return nil
    end
  end

  local cases_args = captured_nodes["_cases_args"]
  local test_name_node = captured_nodes["test.name"]
  local test_def_node = captured_nodes["test.definition"]

  -- Suppress the generic `@test.<modifier>(...)` match when the same
  -- decorated function also has `@test.cases(...)` — the dedicated cases
  -- pattern owns the expansion, and we don't want a redundant bare
  -- function position alongside the per-case ones.
  if
    not cases_args
    and captured_nodes["_dec_attr"]
    and test_def_node
    and has_cases_decorator(test_def_node, source)
  then
    return nil
  end

  -- `@test.cases(...)` expansion — one position per case label.
  if cases_args and test_name_node and test_def_node then
    local func_name = vim.treesitter.get_node_text(test_name_node, source)
    local expanded = expand_cases(cases_args, func_name, file_path, source)
    if expanded then
      return expanded
    end
    -- No enumerable cases (unusual — e.g. dynamic decorator argument). Fall
    -- back to a single bare-function position so the test is still visible.
    return {
      type = "test",
      path = file_path,
      name = func_name,
      range = { test_def_node:range() },
    }
  end

  local match_type
  if captured_nodes["test.name"] then
    match_type = "test"
  elseif captured_nodes["namespace.name"] then
    match_type = "namespace"
  end
  if not match_type then
    return nil
  end
  local name = vim.treesitter.get_node_text(captured_nodes[match_type .. ".name"], source)
  local definition = captured_nodes[match_type .. ".definition"]
  local position = {
    type = match_type,
    path = file_path,
    name = name,
    range = { definition:range() },
  }
  if match_type == "test" and captured_nodes["_docstring"] then
    -- Verify the docstring actually contains `>>>`.
    local docstring_text = vim.treesitter.get_node_text(captured_nodes["_docstring"], source)
    if not docstring_text or not docstring_text:find(">>>") then
      return nil
    end
    -- Function / class / method doctest — tryke addresses class doctests as
    -- flat dotted names (`ClassName.method`) so we flatten here too.
    local doctest_name = name
    local class_name = find_parent_class_name(definition, source)
    if class_name then
      doctest_name = class_name .. "." .. name
    end
    position.name = "doctest: " .. doctest_name
    position._func_name = doctest_name
    position._is_doctest = true
  elseif match_type == "test" then
    local display_name = extract_display_name(definition, source)
    if display_name then
      position.name = display_name
      position._func_name = name
    end
  end
  return position
end

function M.position_id(position, parents)
  local parent_names = {}
  for _, pos in ipairs(parents) do
    -- Skip doctest parents (e.g. class doctests): tryke uses flat dotted
    -- names like `ClassName.method` rather than parent-segmented IDs.
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
