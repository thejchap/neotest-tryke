local lib = require("neotest.lib")
local nio = require("nio")
local config = require("neotest-tryke.config")
local ts = require("neotest-tryke.treesitter")
local results_mod = require("neotest-tryke.results")
local server = require("neotest-tryke.server")

local cfg = config.get()

local adapter = { name = "neotest-tryke" }

function adapter.root(dir)
  return lib.files.match_root_pattern("pyproject.toml")(dir)
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

function adapter.filter_dir(name)
  return not excluded_dirs[name]
end

function adapter.is_test_file(file_path)
  return ts.is_test_file(file_path)
end

function adapter.discover_positions(file_path)
  return lib.treesitter.parse_positions(file_path, ts.query)
end

local function build_direct_spec(args)
  local tree = args.tree
  local position = tree:data()
  local root = adapter.root(position.path)

  local command = { cfg.tryke_command, "test" }

  if position.type == "test" then
    table.insert(command, position.path)
    table.insert(command, "-k")
    table.insert(command, position.name)
  elseif position.type == "file" then
    table.insert(command, position.path)
  elseif position.type == "dir" then
    table.insert(command, position.path)
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

  return {
    command = command,
    cwd = root,
    context = {
      root = root,
    },
    stream = function(output_stream)
      return function()
        local lines = output_stream()
        if not lines or #lines == 0 then
          return {}
        end
        local streamed = {}
        for _, line in ipairs(lines) do
          local ok, decoded = pcall(vim.json.decode, line)
          if ok and decoded and decoded.event == "test_complete" and decoded.result then
            local tryke_result = decoded.result
            local test = tryke_result.test
            if test.file_path then
              local joinpath = vim.fs and vim.fs.joinpath or function(a, b)
                return a .. "/" .. b
              end
              local file = joinpath(root, test.file_path)
              local id = file .. "::" .. test.name
              streamed[id] = results_mod.convert_result(tryke_result)
            end
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
    table.insert(test_ids, relative .. "::" .. position.name)
  else
    for _, pos in tree:iter() do
      if pos.type == "test" then
        local relative = pos.path:sub(#root + 2)
        table.insert(test_ids, relative .. "::" .. pos.name)
      end
    end
  end

  local output_file = nio.fn.tempname()
  local run_complete = nio.control.future()

  return {
    command = { "true" },
    cwd = root,
    context = {
      root = root,
      output_file = output_file,
    },
    strategy = function()
      server.ensure_server(cfg)

      local connect_future = server.connect(cfg.server.host, cfg.server.port)
      connect_future.wait()

      local output_lines = {}
      local streamed_results = {}

      server.on_notification("test_complete", function(msg)
        local line = vim.json.encode(msg.params)
        table.insert(output_lines, line)
        if msg.params and msg.params.result then
          local tryke_result = msg.params.result
          local test = tryke_result.test
          if test.file_path then
            local joinpath = vim.fs and vim.fs.joinpath or function(a, b)
              return a .. "/" .. b
            end
            local file = joinpath(root, test.file_path)
            local id = file .. "::" .. test.name
            streamed_results[id] = results_mod.convert_result(tryke_result)
          end
        end
      end)

      server.on_notification("run_complete", function()
        run_complete.set(true)
      end)

      local params = {}
      if #test_ids > 0 then
        params.tests = test_ids
      end
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
  local output_path = result.output
  local root = spec.context.root

  local content = lib.files.read(output_path)
  if not content or content == "" then
    return {}
  end

  local parsed = results_mod.parse_output(content, root)

  for _, pos in tree:iter() do
    if pos.type == "test" and not parsed[pos.id] then
      parsed[pos.id] = {
        status = "skipped",
        short = pos.name .. ": not run",
      }
    end
  end

  return parsed
end

setmetatable(adapter, {
  __call = function(_, opts)
    cfg = config.get(opts)
    return adapter
  end,
})

return adapter
