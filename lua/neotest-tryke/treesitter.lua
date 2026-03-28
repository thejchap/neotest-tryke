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
  (decorated_definition
    (decorator (call
      function: (attribute
        object: (identifier) @_dec_obj)))
    definition: (function_definition
      name: (identifier) @test.name)) @test.definition
  (#eq? @_dec_obj "test")

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
          -- keyword: @test(name="...")
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
          -- positional: @test("...")
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

function M.build_position(file_path, source, captured_nodes)
  -- module-level doctest (no test.name capture)
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

  -- verify decorator patterns actually matched @test (treesitter predicates may not
  -- be enforced in all environments, so check the captured decorator name in lua)
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

  local match_type = nil
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
    -- verify the docstring actually contains >>>
    local docstring_text = vim.treesitter.get_node_text(captured_nodes["_docstring"], source)
    if not docstring_text or not docstring_text:find(">>>") then
      return nil
    end
    -- function/class/method doctest
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
    -- skip doctest parents (e.g. class doctests) since tryke uses flat dotted names
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
