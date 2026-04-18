local M = {}

local TRYKE_SYMBOLS = { describe = true, test = true, fixture = true, Depends = true }

local cache = {}

local function escape(name)
  return (name:gsub("(%W)", "%%%1"))
end

local function process_names(names, symbol_aliases)
  local comment = names:find("#", 1, true)
  if comment then
    names = names:sub(1, comment - 1)
  end
  for entry in (names .. ","):gmatch("([^,]+),") do
    local nm, al = entry:match("^%s*([%w_]+)%s+as%s+([%w_]+)%s*$")
    if nm and al then
      if TRYKE_SYMBOLS[nm] then
        symbol_aliases[al] = nm
      end
    else
      local bare = entry:match("^%s*([%w_]+)%s*$")
      if bare and TRYKE_SYMBOLS[bare] then
        symbol_aliases[bare] = bare
      end
    end
  end
end

local function parse(source)
  local module_aliases = {}
  local symbol_aliases = {}

  local i = 1
  local len = #source
  while i <= len do
    local line_end = source:find("\n", i, true) or (len + 1)
    local line = source:sub(i, line_end - 1)
    local consumed_to = line_end + 1

    local stripped = line:match("^%s*(.-)%s*$") or ""

    do
      local alias = stripped:match("^import%s+tryke%s+as%s+([%w_]+)%s*$")
      if alias then
        module_aliases[alias] = true
      elseif stripped == "import tryke" or stripped:match("^import%s+tryke%s*#") then
        module_aliases["tryke"] = true
      elseif stripped:match("^import%s+tryke%s*,") or stripped:match("^import%s+.-,%s*tryke%s*,?") then
        module_aliases["tryke"] = true
      end
    end

    local names_part = stripped:match("^from%s+tryke%s+import%s+(.+)$")
    if names_part then
      if names_part:sub(1, 1) == "(" then
        local collected = names_part:sub(2)
        local close_on_line = collected:find(")", 1, true)
        if close_on_line then
          process_names(collected:sub(1, close_on_line - 1), symbol_aliases)
        else
          local j = line_end + 1
          while j <= len do
            local jend = source:find("\n", j, true) or (len + 1)
            local jline = source:sub(j, jend - 1)
            local close_pos = jline:find(")", 1, true)
            if close_pos then
              collected = collected .. " " .. jline:sub(1, close_pos - 1)
              consumed_to = jend + 1
              break
            end
            collected = collected .. " " .. jline
            j = jend + 1
          end
          process_names(collected, symbol_aliases)
        end
      else
        process_names(names_part, symbol_aliases)
      end
    end

    i = consumed_to
  end

  return { module = module_aliases, symbol = symbol_aliases }
end

--- Return the alias table for *source*, building it on first request and
--- caching the result. Callers may treat the returned table as immutable.
---@param source string
---@return { module: table<string, boolean>, symbol: table<string, string> }
function M.get(source)
  local cached = cache[source]
  if cached then
    return cached
  end
  local aliases = parse(source)
  cache[source] = aliases
  return aliases
end

--- Does *name* refer to the tryke module in this file? True when the file
--- contains `import tryke` (bare or aliased) and `name` matches the local
--- binding, or — for legacy tolerance — when `name` is literally `tryke`.
---@param aliases table
---@param name string
---@return boolean
function M.is_module(aliases, name)
  if aliases.module[name] then
    return true
  end
  return name == "tryke"
end

local function has_top_level_def(source, name)
  local esc = escape(name)
  if source:find("^def%s+" .. esc .. "%s*[%(]") then
    return true
  end
  if source:find("\ndef%s+" .. esc .. "%s*[%(]") then
    return true
  end
  if source:find("^async%s+def%s+" .. esc .. "%s*[%(]") then
    return true
  end
  if source:find("\nasync%s+def%s+" .. esc .. "%s*[%(]") then
    return true
  end
  if source:find("^class%s+" .. esc .. "%s*[%(:]") then
    return true
  end
  if source:find("\nclass%s+" .. esc .. "%s*[%(:]") then
    return true
  end
  if source:find("^" .. esc .. "%s*=[^=]") then
    return true
  end
  if source:find("\n" .. esc .. "%s*=[^=]") then
    return true
  end
  return false
end

--- Does the bare name *name* resolve to the tryke symbol *canon*?
---
--- Matches when either (a) `name` is explicitly aliased to `canon` via
--- `from tryke import <canon> [as <name>]`, or (b) `name` is literally
--- `canon` — the legacy heuristic that keeps snippet-style test files
--- working even with no visible import. A top-level `def`/`class`/
--- assignment shadows in either case, matching Python scoping.
---@param aliases table
---@param source string
---@param name string
---@param canon string
---@return boolean
function M.is_tryke_symbol(aliases, source, name, canon)
  if has_top_level_def(source, name) then
    return false
  end
  return aliases.symbol[name] == canon or name == canon
end

return M
