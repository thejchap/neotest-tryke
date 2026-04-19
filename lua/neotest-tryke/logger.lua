--- Plugin-scoped logger. Writes to `stdpath("log")/neotest-tryke.log`
--- so the user can crank trace-level verbosity on the plugin without
--- drowning the shared `neotest.log` in noise — handy for diagnosing
--- discovery mismatches and test-run failures.
local M = {}

local LEVELS = { TRACE = 0, DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

local level = LEVELS.INFO
local file_handle = nil
local file_path = nil

local function get_logpath()
  local ok, dir = pcall(vim.fn.stdpath, "log")
  if ok and type(dir) == "string" and dir ~= "" then
    return dir
  end
  return vim.fn.stdpath("cache")
end

local function resolve_file()
  if file_handle then
    return file_handle
  end
  local dir = get_logpath()
  pcall(vim.fn.mkdir, dir, "p")
  file_path = dir .. "/neotest-tryke.log"
  local ok, handle = pcall(io.open, file_path, "a+")
  if ok and handle then
    file_handle = handle
  end
  return file_handle
end

function M.filename()
  if not file_path then
    resolve_file()
  end
  return file_path
end

--- Set the minimum level that will be written. Accepts a string
--- (`"trace"`, `"debug"`, `"info"`, `"warn"`, `"error"`) or a numeric
--- `vim.log.levels` value. Invalid input leaves the level unchanged
--- and logs a warning.
---@param v string|number
function M.set_level(v)
  if type(v) == "string" then
    local resolved = LEVELS[v:upper()]
    if resolved == nil then
      M.warn("logger: ignoring unknown log_level:", v)
      return
    end
    level = resolved
  elseif type(v) == "number" then
    level = v
  end
end

function M.get_level()
  return level
end

local function write(label, level_num, ...)
  if level_num < level then
    return
  end
  local f = resolve_file()
  if not f then
    return
  end
  local argc = select("#", ...)
  local parts = {
    label,
    "|",
    os.date("%FT%H:%M:%SZ%z"),
    "|",
  }
  for i = 1, argc do
    local arg = select(i, ...)
    if arg == nil then
      table.insert(parts, "<nil>")
    elseif type(arg) == "string" then
      table.insert(parts, arg)
    elseif type(arg) == "table" and arg.__tostring then
      table.insert(parts, arg.__tostring(arg))
    else
      table.insert(parts, vim.inspect(arg))
    end
  end
  f:write(table.concat(parts, " "), "\n")
  f:flush()
end

function M.trace(...)
  write("TRACE", LEVELS.TRACE, ...)
end

function M.debug(...)
  write("DEBUG", LEVELS.DEBUG, ...)
end

function M.info(...)
  write("INFO", LEVELS.INFO, ...)
end

function M.warn(...)
  write("WARN", LEVELS.WARN, ...)
end

function M.error(...)
  write("ERROR", LEVELS.ERROR, ...)
end

return M
