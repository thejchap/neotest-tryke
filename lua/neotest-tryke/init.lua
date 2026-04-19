local lib = require("neotest.lib")
local nio = require("nio")
local config = require("neotest-tryke.config")
local ts = require("neotest-tryke.treesitter")
local results_mod = require("neotest-tryke.results")
local server = require("neotest-tryke.server")
local log = require("neotest-tryke.logger")

local cfg = config.get()
log.set_level(cfg.log_level)

local function shell_escape(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local adapter = { name = "neotest-tryke" }

function adapter.root(dir)
  local root = lib.files.match_root_pattern("pyproject.toml")(dir)
  if not root then
    return nil
  end
  if not ts.is_tryke_project(root) then
    return nil
  end
  return root
end

local excluded_dirs = {
  [".venv"] = true,
  ["venv"] = true,
  ["__pycache__"] = true,
  [".git"] = true,
  ["node_modules"] = true,
  [".mypy_cache"] = true,
  [".ruff_cache"] = true,
  ["target"] = true,
  [".tox"] = true,
}

--- Parse the `[tool.tryke] exclude = [...]` list out of pyproject.toml.
--- Mirrors `tryke_config::TrykeConfig::from_toml_str` in the Rust crate
--- so discovery in the plugin respects whatever the project has already
--- told the tryke CLI to skip (e.g. the 45K-line benchmark suites).
---@param pyproject_path string
---@return string[]
local function parse_tryke_excludes(pyproject_path)
  local f = io.open(pyproject_path, "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  -- Anchor on `[tool.tryke]` and stop at the next `[section]` header (or
  -- end-of-file). `.-` is lazy so we grab only this section's body.
  local section = content:match("%[tool%.tryke%]%s*\n(.-)\n%[[%w_%.]+%]")
    or content:match("%[tool%.tryke%]%s*\n(.-)$")
  if not section then
    return {}
  end
  local raw = section:match("exclude%s*=%s*%[(.-)%]")
  if not raw then
    return {}
  end
  local list = {}
  for entry in raw:gmatch('"([^"]+)"') do
    table.insert(list, entry)
  end
  for entry in raw:gmatch("'([^']+)'") do
    table.insert(list, entry)
  end
  return list
end

local excludes_cache = {}

local function get_project_excludes(root)
  if root == nil then
    return {}
  end
  local cached = excludes_cache[root]
  if cached then
    return cached
  end
  local list = parse_tryke_excludes(root .. "/pyproject.toml")
  excludes_cache[root] = list
  return list
end

function adapter.filter_dir(name, rel_path, root)
  if excluded_dirs[name] then
    return false
  end
  if rel_path ~= nil then
    for _, pattern in ipairs(get_project_excludes(root)) do
      if rel_path == pattern then
        return false
      end
    end
  end
  return true
end

function adapter.is_test_file(file_path)
  return ts.is_test_file(file_path)
end

function adapter.discover_positions(file_path)
  if not ts.is_test_file(file_path) then
    log.trace("discover_positions: skip (not a test file):", file_path)
    return nil
  end
  log.debug("discover_positions:", file_path, "mode =", cfg.discovery)
  if cfg.discovery == "cli" then
    local root = adapter.root(file_path)
    local ok, result = pcall(
      require("neotest-tryke.cli_discovery").discover,
      file_path,
      root,
      cfg.tryke_command
    )
    if ok then
      return result
    end
    log.warn("discover_positions: cli discovery failed, falling back to treesitter:", tostring(result))
  end
  return lib.treesitter.parse_positions(file_path, ts.query, {
    build_position = 'require("neotest-tryke.treesitter").build_position',
    position_id = ts.position_id,
    nested_tests = true,
  })
end

local function build_direct_spec(args)
  local tree = args.tree
  local position = tree:data()
  local root = adapter.root(position.path)

  local command = { cfg.tryke_command, "test" }

  local function to_relative(abs_path)
    if root and abs_path:sub(1, #root) == root then
      return abs_path:sub(#root + 2)
    end
    return abs_path
  end

  if position.type == "test" then
    table.insert(command, to_relative(position.path))
    table.insert(command, "-k")
    table.insert(command, position._func_name or position.name)
  elseif position.type == "namespace" then
    table.insert(command, to_relative(position.path))
    local test_names = {}
    for _, pos in tree:iter() do
      if pos.type == "test" then
        table.insert(test_names, pos._func_name or pos.name)
      end
    end
    if #test_names > 0 then
      table.insert(command, "-k")
      table.insert(command, table.concat(test_names, " or "))
    end
  elseif position.type == "file" then
    table.insert(command, to_relative(position.path))
  elseif position.type == "dir" then
    table.insert(command, to_relative(position.path))
  end

  table.insert(command, "--reporter")
  table.insert(command, "json")

  if cfg.workers then
    table.insert(command, "--workers")
    table.insert(command, tostring(cfg.workers))
  end

  if cfg.fail_fast then
    table.insert(command, "--fail-fast")
  end

  for _, arg in ipairs(cfg.args) do
    table.insert(command, arg)
  end

  if args.extra_args then
    for _, arg in ipairs(args.extra_args) do
      table.insert(command, arg)
    end
  end

  local results_path = nio.fn.tempname()
  lib.files.write(results_path, "")
  local stream_data, stop_stream = lib.files.stream_lines(results_path)

  -- Build shell command string for stdout redirection to bypass PTY corruption
  local cmd_parts = {}
  for _, arg in ipairs(command) do
    table.insert(cmd_parts, shell_escape(arg))
  end
  local cmd_str = table.concat(cmd_parts, " ")

  log.debug("build_direct_spec: command =", cmd_str)
  log.debug("build_direct_spec: results_path =", results_path)
  log.debug("build_direct_spec: cwd =", root)

  return {
    command = { "sh", "-c", cmd_str .. " > " .. shell_escape(results_path) },
    cwd = root,
    context = {
      root = root,
      results_path = results_path,
      stop_stream = stop_stream,
    },
    stream = function()
      return function()
        local lines = stream_data()
        local streamed = {}
        for _, line in ipairs(lines) do
          local ok, decoded = pcall(vim.json.decode, line)
          if ok and decoded and decoded.event == "test_complete" and decoded.result then
            local tryke_result = decoded.result
            local test = tryke_result.test
            if test.file_path then
              local id = results_mod.build_id(root, test)
              local converted = results_mod.convert_result(tryke_result)
              log.trace("stream: test_complete", id, "status =", converted.status)
              streamed[id] = converted
            end
          elseif ok and decoded then
            log.trace("stream: event", decoded.event)
          end
        end
        return streamed
      end
    end,
  }
end

local function build_server_spec(args)
  local tree = args.tree
  local position = tree:data()
  local root = adapter.root(position.path)

  local test_ids = {}
  if position.type == "test" then
    local relative = position.path:sub(#root + 2)
    table.insert(test_ids, relative .. "::" .. (position._func_name or position.name))
  else
    for _, pos in tree:iter() do
      if pos.type == "test" then
        local relative = pos.path:sub(#root + 2)
        table.insert(test_ids, relative .. "::" .. (pos._func_name or pos.name))
      end
    end
  end
  log.debug("build_server_spec: sending", #test_ids, "test id(s) to server")
  for _, tid in ipairs(test_ids) do
    log.trace("build_server_spec: test id =", tid)
  end

  local output_file = nio.fn.tempname()
  local run_complete = nio.control.future()

  return {
    command = { "true" },
    cwd = root,
    context = {
      root = root,
      results_path = output_file,
    },
    strategy = function()
      server.ensure_server(cfg)

      local connect_future = server.connect(cfg.server.host, cfg.server.port)
      connect_future.wait()

      local output_lines = {}
      local streamed_results = {}

      server.on_notification("test_complete", function(msg)
        local line = vim.json.encode({ event = "test_complete", result = msg.params.result })
        table.insert(output_lines, line)
        if msg.params and msg.params.result then
          local tryke_result = msg.params.result
          local test = tryke_result.test
          if test.file_path then
            local id = results_mod.build_id(root, test)
            log.trace("server: test_complete id =", id, "status =", tryke_result.outcome and tryke_result.outcome.status)
            streamed_results[id] = results_mod.convert_result(tryke_result)
          end
        end
      end)

      server.on_notification("run_start", function(msg)
        local tests = msg.params and msg.params.tests or {}
        log.debug("server: run_start — server picked up", #tests, "test(s)")
      end)

      server.on_notification("run_complete", function()
        run_complete.set(true)
      end)

      local params = {}
      if #test_ids > 0 then
        params.tests = test_ids
      end
      log.debug("server: sending run with", #test_ids, "test id(s)")
      local response_future = server.send_request("run", params)

      run_complete.wait()

      local f = io.open(output_file, "w")
      if f then
        for _, line in ipairs(output_lines) do
          f:write(line .. "\n")
        end
        f:close()
      end

      local response = response_future.wait()
      local exit_code = 0
      if response and response.result and response.result.summary then
        local summary = response.result.summary
        if summary.failed > 0 or summary.errors > 0 then
          exit_code = 1
        end
      end

      server.disconnect()

      return {
        output = function()
          return output_file
        end,
        is_complete = function()
          return true
        end,
        result = function()
          return exit_code
        end,
        attach = function() end,
        stop = function()
          server.disconnect()
        end,
        output_stream = function()
          local done = false
          return function()
            if done then
              return nil
            end
            done = true
            local lines = {}
            for _, line in ipairs(output_lines) do
              table.insert(lines, line)
            end
            return lines
          end
        end,
      }
    end,
  }
end

function adapter.build_spec(args)
  local position = args.tree and args.tree:data()
  log.info(
    "build_spec: mode =",
    cfg.mode,
    "position =",
    position and (position.type .. " " .. position.id) or "<unknown>"
  )
  local use_server = false

  if cfg.mode == "server" then
    use_server = true
  elseif cfg.mode == "auto" then
    local ok = pcall(function()
      local f = server.connect(cfg.server.host, cfg.server.port)
      f.wait()
      local pong = server.send_request("ping")
      pong.wait()
      server.disconnect()
    end)
    if not ok then
      server.disconnect()
    end
    use_server = ok
  end

  if use_server then
    return build_server_spec(args)
  end

  return build_direct_spec(args)
end

function adapter.results(spec, result, tree)
  if spec.context.stop_stream then
    spec.context.stop_stream()
  end

  local output_path = spec.context.results_path or result.output
  local root = spec.context.root

  log.info("results: exit code =", result.code, "output_path =", output_path, "root =", root)

  local content = lib.files.read(output_path)
  log.debug("results: raw output length =", content and #content or "nil")
  log.trace("results: raw output =", content and content:sub(1, 2000) or "nil")

  if not content or content == "" then
    log.warn("results: tryke produced no output — every tree test will be reported as skipped")
    local empty = {}
    for _, pos in tree:iter() do
      if pos.type == "test" then
        empty[pos.id] = { status = "skipped", short = pos.name .. ": not run" }
      end
    end
    return empty
  end

  local parsed = results_mod.parse_output(content, root)
  log.debug("results: parsed", vim.tbl_count(parsed), "ids from tryke output")
  for id in pairs(parsed) do
    log.trace("results: parsed id", id, "status =", parsed[id].status)
  end

  local unmatched = {}
  for _, pos in tree:iter() do
    if pos.type == "test" then
      if not parsed[pos.id] then
        table.insert(unmatched, pos.id)
        parsed[pos.id] = {
          status = "skipped",
          short = pos.name .. ": not run",
        }
      end
    end
  end
  if #unmatched > 0 then
    log.warn(
      "results:",
      #unmatched,
      "tree test(s) had no matching tryke result — id format drift? sample:",
      unmatched[1]
    )
    log.debug("results: unmatched ids =", unmatched)
  end

  return parsed
end

setmetatable(adapter, {
  __call = function(_, opts)
    cfg = config.get(opts)
    log.set_level(cfg.log_level)
    log.info("setup:", "discovery =", cfg.discovery, "mode =", cfg.mode, "log_level =", cfg.log_level)
    return adapter
  end,
})

return adapter
