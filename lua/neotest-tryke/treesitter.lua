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

function M.build_position(file_path, source, captured_nodes)
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
  if match_type == "test" then
    local display_name = extract_display_name(definition, source)
    if display_name then
      position.name = display_name
      position._func_name = name
    end
  end
  return position
end

function M.position_id(position, parents)
  return table.concat(
    vim.tbl_flatten({
      position.path,
      vim.tbl_map(function(pos) return pos._func_name or pos.name end, parents),
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
  for i = 1, 50 do
    local line = f:read("*l")
    if not line then
      break
    end
    if line:find("from tryke import") or line:find("import tryke") then
      f:close()
      return true
    end
  end
  f:close()
  return false
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
