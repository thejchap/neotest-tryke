local nio = require("nio")
local log = require("neotest-tryke.logger")

local M = {}

local handle = nil
local pending_requests = {}
local notification_handlers = {}
local request_id = 0
local server_process = nil
local read_buffer = ""
-- Captured at the most recent `ensure_server` call so the VimLeavePre
-- autocmd can honour `server.auto_stop` (the config object isn't in
-- scope from the autocmd otherwise, and the docs promise the flag is
-- respected — without this, `auto_stop = false` was a silent no-op).
local last_config = nil

function M.is_connected()
  return handle ~= nil and not handle:is_closing()
end

--- Build the `args` array and `env` table passed to `vim.uv.spawn` for the
--- tryke server child. Pure: no side effects, easy to unit-test.
---
--- Returns `(args, env)`:
---  * `args`: positional arguments for `tryke server`. Always carries
---    `server --port <port>`; appends `--python <path>` when set.
---  * `env`: nil when no env override is needed (libuv inherits the parent
---    env in that case). Otherwise an array of `"KEY=VALUE"` strings —
---    libuv resets the env when `env` is provided, so we have to splice
---    the parent env ourselves before adding `TRYKE_LOG`.
---
---@param config table  the resolved adapter config table
---@param port number   the server port to bind
---@return string[] args
---@return string[]|nil env
function M._build_spawn_options(config, port)
  local args = { "server", "--port", tostring(port) }
  if config.python then
    table.insert(args, "--python")
    table.insert(args, config.python)
  end

  local env = nil
  if config.tryke_log_level then
    env = {}
    for k, v in pairs(vim.uv.os_environ() or {}) do
      table.insert(env, k .. "=" .. v)
    end
    table.insert(env, "TRYKE_LOG=" .. config.tryke_log_level)
  end

  return args, env
end

function M.connect(host, port)
  local endpoint = host .. ":" .. tostring(port)
  log.debug("server: connect", endpoint)
  local future = nio.control.future()

  handle = vim.uv.new_tcp()
  read_buffer = ""

  vim.uv.tcp_connect(handle, host, port, function(err)
    if err then
      log.debug("server: connect failed", endpoint, "—", err)
      handle:close()
      handle = nil
      future.set_error(err)
      return
    end

    handle:read_start(function(read_err, data)
      if read_err then
        log.warn("server: read error on", endpoint, "—", read_err)
        M.disconnect()
        return
      end
      if data then
        M._on_data(data)
      end
    end)

    log.debug("server: connected", endpoint)
    future.set(true)
  end)

  return future
end

function M.disconnect()
  if handle and not handle:is_closing() then
    handle:read_stop()
    handle:close()
  end
  handle = nil
  read_buffer = ""
  pending_requests = {}
end

function M.send_request(method, params)
  request_id = request_id + 1
  local id = request_id

  local message = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }) .. "\n"

  log.trace("server: request id =", id, "method =", method, "params =", params)

  local future = nio.control.future()
  pending_requests[id] = future

  ---@diagnostic disable-next-line: need-check-nil, undefined-field
  handle:write(message)

  return future
end

function M._on_data(data)
  read_buffer = read_buffer .. data

  while true do
    local newline_pos = read_buffer:find("\n")
    if not newline_pos then
      break
    end

    local line = read_buffer:sub(1, newline_pos - 1)
    read_buffer = read_buffer:sub(newline_pos + 1)

    if line ~= "" then
      local ok, decoded = pcall(vim.json.decode, line)
      if ok and decoded then
        if decoded.id and pending_requests[decoded.id] then
          local future = pending_requests[decoded.id]
          pending_requests[decoded.id] = nil
          future.set(decoded)
        elseif decoded.method and not decoded.id then
          local handler = notification_handlers[decoded.method]
          if handler then
            handler(decoded)
          end
        end
      end
    end
  end
end

function M.on_notification(method, handler)
  notification_handlers[method] = handler
end

--- How long to wait for a `did_change` ack before giving up and
--- proceeding to `run`. Matches the bound used for `run_complete` in
--- init.lua so the run can't hang on a slow / unresponsive server even
--- if its FS watcher races us.
local DID_CHANGE_TIMEOUT_MS = 2000

--- Outcome of a `send_did_change` call. The caller can log this for
--- diagnosability; the run should proceed in every branch.
local DID_CHANGE = {
  ACKED = "acked",                  -- server replied with a result
  UNSUPPORTED = "unsupported",      -- METHOD_NOT_FOUND (older server)
  ERROR = "error",                  -- server returned a non-NOT_FOUND error
  TIMEOUT = "timeout",              -- no reply within DID_CHANGE_TIMEOUT_MS
  MALFORMED = "malformed",          -- reply has neither result nor error
}
M.DID_CHANGE = DID_CHANGE

--- Send an in-band `did_change` notice to the server for the given file
--- paths and wait (bounded) for the response. Must be called BEFORE the
--- corresponding `run` on the same connection — that ordering is what
--- closes the server-mode race where a `run` arriving inside the
--- watcher's debounce window dispatches against workers whose cached
--- `sys.modules` predates the save.
---
--- Three classes of fallback, all of which return control to the caller
--- so the run can proceed:
---   * METHOD_NOT_FOUND → older server; the FS-watcher path covers us
---     eventually (with today's race).
---   * Timeout → server never replied; we can't block the run forever
---     even if it means racing this iteration.
---   * Any other error or malformed payload → log + proceed.
---
--- @param paths string[] absolute filesystem paths
--- @return string outcome one of the `DID_CHANGE` constants — `ACKED`
---   means the server confirmed the dirty mark; every other value means
---   the run may race the on-disk content.
function M.send_did_change(paths)
  local METHOD_NOT_FOUND = -32601
  local future = M.send_request("did_change", { paths = paths })

  -- Bounded wait: `future.wait()` would block forever if the server
  -- accepted the connection but never replied (slow discovery,
  -- swallowed reply, deadlock, M.disconnect() clearing the pending
  -- requests table). Race the wait against a sleep, exactly like
  -- `run_complete_event` does in init.lua:470-483. nio.first returns
  -- as soon as either branch completes.
  local resp = nil
  local timed_out = true
  nio.first({
    function()
      resp = future.wait()
      timed_out = false
    end,
    function()
      nio.sleep(DID_CHANGE_TIMEOUT_MS)
    end,
  })

  if timed_out then
    log.warn("server: did_change timed out after", DID_CHANGE_TIMEOUT_MS, "ms — proceeding")
    return DID_CHANGE.TIMEOUT
  end

  if resp and resp.error then
    if resp.error.code == METHOD_NOT_FOUND then
      log.debug("server: did_change unsupported (older server), falling through")
      return DID_CHANGE.UNSUPPORTED
    end
    log.warn("server: did_change error", resp.error.code, resp.error.message)
    return DID_CHANGE.ERROR
  end

  -- A well-formed response from the server has `result` set (we expect
  -- "ok" but accept anything truthy). Treating "no error key" as
  -- success would let a misbehaving server claim ack with no payload.
  if not (resp and resp.result ~= nil) then
    log.warn("server: did_change malformed response", vim.inspect(resp))
    return DID_CHANGE.MALFORMED
  end

  log.trace("server: did_change ack", paths)
  return DID_CHANGE.ACKED
end

function M.ensure_server(config)
  last_config = config
  local host = config.server.host
  local port = config.server.port
  local endpoint = host .. ":" .. tostring(port)

  log.info("server: ensure_server", endpoint)

  local ok = pcall(function()
    local f = M.connect(host, port)
    f.wait()
    local pong = M.send_request("ping")
    pong.wait()
    M.disconnect()
  end)

  if ok then
    log.info("server: reusing existing server at", endpoint)
    return true
  end

  M.disconnect()

  if not config.server.auto_start then
    log.error("server: not reachable at", endpoint, "and auto_start is disabled")
    error("tryke server not reachable and auto_start is disabled")
  end

  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  local cmd = config.tryke_command or "tryke"
  local server_args, server_env = M._build_spawn_options(config, port)

  log.info("server: spawning", cmd, table.concat(server_args, " "))
  server_process = vim.uv.spawn(cmd, {
    args = server_args,
    env = server_env,
    stdio = { nil, stdout, stderr },
  }, function(code, signal)
    log.info("server: process exited code =", code, "signal =", signal)
    server_process = nil
  end)

  if not server_process then
    log.error("server: failed to spawn", cmd)
    error("failed to spawn tryke server")
  end

  log.debug("server: spawned pid", server_process and server_process:get_pid() or "<unknown>")

  local timeout = 10000
  local interval = 100
  local elapsed = 0

  while elapsed < timeout do
    nio.sleep(interval)
    elapsed = elapsed + interval

    local connected = pcall(function()
      local f = M.connect(host, port)
      f.wait()
      local pong = M.send_request("ping")
      pong.wait()
      M.disconnect()
    end)

    if connected then
      log.info("server: ready after", elapsed, "ms")
      return true
    end

    M.disconnect()
  end

  log.error("server: failed to start within", timeout, "ms")
  M.stop_server()
  error("tryke server failed to start within timeout")
end

function M.stop_server()
  if server_process then
    server_process:kill("sigterm")
    server_process = nil
  end
  M.disconnect()
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("neotest_tryke_cleanup", { clear = true }),
  callback = function()
    -- Default to true when ensure_server was never called (the autocmd
    -- still fires) so we keep the documented default behaviour.
    local auto_stop = true
    if last_config and last_config.server and last_config.server.auto_stop ~= nil then
      auto_stop = last_config.server.auto_stop
    end
    if auto_stop then
      M.stop_server()
    else
      M.disconnect()
    end
  end,
})

return M
