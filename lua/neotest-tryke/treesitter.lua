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
