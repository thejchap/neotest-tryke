local nio = require("nio")

local M = {}

local handle = nil
local pending_requests = {}
local notification_handlers = {}
local request_id = 0
local server_process = nil
local read_buffer = ""

function M.is_connected()
  return handle ~= nil and not handle:is_closing()
end

function M.connect(host, port)
  local future = nio.control.future()

  handle = vim.uv.new_tcp()
  read_buffer = ""

  vim.uv.tcp_connect(handle, host, port, function(err)
    if err then
      handle:close()
      handle = nil
      future.set_error(err)
      return
    end

    handle:read_start(function(read_err, data)
      if read_err then
        M.disconnect()
        return
      end
      if data then
        M._on_data(data)
      end
    end)

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

function M.ensure_server(config)
  local host = config.server.host
  local port = config.server.port

  local ok = pcall(function()
    local f = M.connect(host, port)
    f.wait()
    local pong = M.send_request("ping")
    pong.wait()
    M.disconnect()
  end)

  if ok then
    return true
  end

  M.disconnect()

  if not config.server.auto_start then
    error("tryke server not reachable and auto_start is disabled")
  end

  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  server_process = vim.uv.spawn(config.tryke_command or "tryke", {
    args = { "server", "--port", tostring(port) },
    stdio = { nil, stdout, stderr },
  }, function()
    server_process = nil
  end)

  if not server_process then
    error("failed to spawn tryke server")
  end

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
      return true
    end

    M.disconnect()
  end

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
    M.stop_server()
  end,
})

return M
