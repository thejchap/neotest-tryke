local M = {}

local TRYKE_SYMBOLS = { describe = true, test = true, fixture = true, Depends = true }

local cache = {}

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

--- Walk the source once and record every top-level `def`/`class`/simple
--- assignment name. The returned set powers the shadowing check in
--- `is_tryke_symbol` in O(1) without rescanning source on each call —
--- critical for large generated test suites where naive per-decorator
--- scanning is quadratic in file size.
local function record_top_level_defs(line, locally_defined)
  -- Only top-level lines (no leading indent) can shadow imported names.
  local first = line:sub(1, 1)
  if first == " " or first == "\t" or first == "#" or first == "" then
    return
  end
  local name = line:match("^def%s+([%w_]+)")
    or line:match("^async%s+def%s+([%w_]+)")
    or line:match("^class%s+([%w_]+)")
  if name then
    locally_defined[name] = true
    return
  end
  -- Simple assignment `<name> = …`. Require a word char on the LHS so we
  -- don't misfire on `obj.attr =` or `x[0] =`; require the `=` to not be
  -- `==` so comparisons in early expression statements are skipped.
  local assigned = line:match("^([%w_]+)%s*=[^=]")
  if assigned then
    locally_defined[assigned] = true
  end
end

local function parse(source)
  local module_aliases = {}
  local symbol_aliases = {}
  local locally_defined = {}

  local i = 1
  local len = #source
  while i <= len do
    local line_end = source:find("\n", i, true) or (len + 1)
    local line = source:sub(i, line_end - 1)
    local consumed_to = line_end + 1

    local stripped = line:match("^%s*(.-)%s*$") or ""

    record_top_level_defs(line, locally_defined)

    do
      local alias = stripped:match("^import%s+tryke%s+as%s+([%w_]+)%s*$")
      if alias then
        module_aliases[alias] = true
      elseif stripped == "import tryke" or stripped:match("^import%s+tryke%s*#") then
        module_aliases["tryke"] = true
      elseif
        stripped:match("^import%s+tryke%s*,") or stripped:match("^import%s+.-,%s*tryke%s*,?")
      then
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

  return {
    module = module_aliases,
    symbol = symbol_aliases,
    locally_defined = locally_defined,
  }
end

--- Return the alias table for *source*, building it on first request and
--- caching the result. Callers may treat the returned table as immutable.
---@param source string
---@return { module: table<string, boolean>, symbol: table<string, string>, locally_defined: table<string, boolean> }
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

--- Does the bare name *name* resolve to the tryke symbol *canon*?
---
--- Matches when either (a) `name` is explicitly aliased to `canon` via
--- `from tryke import <canon> [as <name>]`, or (b) `name` is literally
--- `canon` — the legacy heuristic that keeps snippet-style test files
--- working even with no visible import. A top-level `def`/`class`/
--- assignment in the same module shadows in either case, matching
--- Python scoping.
---
--- The `source` parameter is accepted for API stability; the actual
--- shadowing check reads the pre-computed `locally_defined` set from
--- `aliases`.
---@param aliases table
---@param _source string
---@param name string
---@param canon string
---@return boolean
function M.is_tryke_symbol(aliases, _source, name, canon)
  -- Fast path: name can't possibly refer to the tryke symbol. This short-
  -- circuit keeps us from doing any set lookup for the flood of unrelated
  -- decorators (`@overload`, `@property`, `@staticmethod`, …) that show
  -- up in real codebases.
  if name ~= canon and aliases.symbol[name] ~= canon then
    return false
  end
  return not aliases.locally_defined[name]
end

return M
