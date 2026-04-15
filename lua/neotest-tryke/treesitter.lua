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
]]

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

--- Build neotest positions from a query match. Handles `@test.cases` by
--- expanding one decorated function into one position per case label; falls
--- back to neotest's default one-match-one-position behavior otherwise.
---@param file_path string
---@param source string
---@param captured_nodes table<string, TSNode>
---@return table|table[]|nil
function M._build_position(file_path, source, captured_nodes)
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
  if cases_args and test_name_node and test_def_node then
    local func_name = vim.treesitter.get_node_text(test_name_node, source)
    local range = { test_def_node:range() }
    local positions = {}

    for i = 0, cases_args:named_child_count() - 1 do
      local child = cases_args:named_child(i)
      if child then
        local ctype = child:type()
        if ctype == "keyword_argument" then
          -- For `keyword_argument`, the first named child is the `name`
          -- identifier and the second is the `value`.
          local name_node = child:named_child(0)
          if name_node and name_node:type() == "identifier" then
            local label = vim.treesitter.get_node_text(name_node, source)
            table.insert(positions, {
              type = "test",
              path = file_path,
              name = func_name .. "[" .. label .. "]",
              range = range,
            })
          end
        elseif ctype == "list" then
          for j = 0, child:named_child_count() - 1 do
            local elem = child:named_child(j)
            if elem and elem:type() == "tuple" and elem:named_child_count() >= 1 then
              local first = elem:named_child(0)
              if first and first:type() == "string" then
                local raw = vim.treesitter.get_node_text(first, source)
                -- Strip surrounding quotes from the string literal.
                local label = raw:sub(2, -2)
                table.insert(positions, {
                  type = "test",
                  path = file_path,
                  name = func_name .. "[" .. label .. "]",
                  range = range,
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
    -- No enumerable cases (unusual — e.g. dynamic decorator argument). Fall
    -- back to a single bare-function position so the test is still visible.
    return {
      type = "test",
      path = file_path,
      name = func_name,
      range = range,
    }
  end

  local match_type
  if captured_nodes["test.name"] then
    match_type = "test"
  elseif captured_nodes["namespace.name"] then
    match_type = "namespace"
  else
    return nil
  end
  local name_node = captured_nodes[match_type .. ".name"]
  local def_node = captured_nodes[match_type .. ".definition"]
  if not name_node or not def_node then
    return nil
  end
  return {
    type = match_type,
    path = file_path,
    name = vim.treesitter.get_node_text(name_node, source),
    range = { def_node:range() },
  }
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
