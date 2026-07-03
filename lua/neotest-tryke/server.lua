local nio = require("nio")
local log = require("neotest-tryke.logger")

local M = {}

-- The tryke server speaks newline-delimited JSON-RPC 2.0 over the spawned
-- process's stdin/stdout, LSP-style (tryke PR #148 removed the TCP
-- listener and the `--port` flag). The transport IS the child process:
-- spawning it opens the session, and closing its stdin delivers EOF —
-- the server's clean-shutdown signal.
local pending_requests = {}
local notification_handlers = {}
local request_id = 0
local server_process = nil
local stdin_pipe = nil
local read_buffer = ""

--- True when the session's server process is alive AND its stdin is
--- still writable — i.e. we can send requests right now.
function M.is_running()
  return server_process ~= nil
    and not server_process:is_closing()
    and stdin_pipe ~= nil
    and not stdin_pipe:is_closing()
end

--- Resolve every in-flight request future with an error. Called when the
--- transport dies (process exit or explicit stop): with stdio there is no
--- reconnect, so a pending reply can never arrive — leaving the futures
--- unset would hang any coroutine still waiting on them.
local function fail_pending(reason)
  local pending = pending_requests
  pending_requests = {}
  for _, future in pairs(pending) do
    if not future.is_set() then
      future.set_error(reason)
    end
  end
end

--- React to the readable half of the transport dying: a stdout read
--- error, or EOF while the process is somehow still around. With stdio
--- the child's stdout is the *only* way replies come back, so once it's
--- gone every in-flight request is unanswerable and any future one would
--- hang (`is_running()` would still say true because the process handle
--- and stdin are intact).
---
--- Fail the pending futures right away, and — when this is still the
--- active process — mark the session down *synchronously* (nil the
--- handle, close stdin) so a `send_request` landing between now and the
--- deferred reap errors cleanly instead of writing into a dead stdout.
--- Closing stdin also doubles as the graceful stop nudge (EOF).
---
--- Then reap the *specific* process this fired for, deferred to the main
--- loop (this runs in a libuv read callback / fast event context where
--- `stop_server`'s bounded waits are illegal). Crucially we capture
--- `handle` and never touch the module-global `server_process` in the
--- deferred part: by the time it runs, the next run may already have
--- respawned a *new* server, and an unconditional `stop_server()` would
--- tear that one down. The dead process's own exit callback closes its
--- pipes/handle; the deferred SIGTERM (then SIGKILL) only bites a process
--- that ignored the stdin EOF above.
---
--- How long to wait after the SIGTERM before forcing SIGKILL. Same
--- magnitude as `stop_server`'s SIGTERM grace (STOP_SIGTERM_WAIT_MS), but
--- defined here because that constant isn't in lexical scope this early.
local ON_TRANSPORT_LOST_SIGKILL_MS = 1000

local function on_transport_lost(reason, handle)
  fail_pending(reason)

  if server_process == handle then
    server_process = nil
    if stdin_pipe and not stdin_pipe:is_closing() then
      stdin_pipe:close()
    end
    stdin_pipe = nil
    read_buffer = ""
  end

  vim.schedule(function()
    if handle and not handle:is_closing() then
      pcall(function()
        handle:kill("sigterm")
      end)
    end
  end)

  -- SIGKILL escalation: a process that ignored both the stdin EOF and the
  -- SIGTERM above would otherwise linger as a stray tryke server (holding
  -- its worker pool). `server_process` is already nilled, so `stop_server`
  -- won't cover this handle — escalate on the captured handle directly. A
  -- process that already exited has a closing handle by now, so this
  -- no-ops for the common case.
  vim.defer_fn(function()
    if handle and not handle:is_closing() then
      log.warn("server: lost-transport process ignored SIGTERM — sending SIGKILL")
      pcall(function()
        handle:kill("sigkill")
      end)
    end
  end, ON_TRANSPORT_LOST_SIGKILL_MS)
end

--- Build the `args` array and `env` table passed to `vim.uv.spawn` for the
--- tryke server child. Pure: no side effects, easy to unit-test.
---
--- Returns `(args, env)`:
---  * `args`: positional arguments for `tryke server`. The stdio server
---    takes no `--port` (removed in tryke PR #148); appends
---    `--python <path>` when set.
---  * `env`: nil when no env override is needed (libuv inherits the parent
---    env in that case). Otherwise an array of `"KEY=VALUE"` strings —
---    libuv resets the env when `env` is provided, so we have to splice
---    the parent env ourselves before adding `TRYKE_LOG`.
---
---@param config table  the resolved adapter config table
---@return string[] args
---@return string[]|nil env
function M._build_spawn_options(config)
  local args = { "server" }
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

--- Send a JSON-RPC request and return the future that resolves when the
--- server replies. The future is keyed by id in `pending_requests`; if
--- the caller gives up on the wait it should call `M.cancel_request(id)`
--- to avoid leaking an orphaned entry that a late server reply would
--- silently resolve. Errors if the server isn't running — with stdio
--- there is no separate "connect" step to have forgotten; a dead server
--- means `ensure_server` must run first.
--- Returns `(future, id)`.
function M.send_request(method, params)
  if not M.is_running() then
    error("tryke server is not running")
  end

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

  -- `M.is_running()` above already guarantees `stdin_pipe` is a live,
  -- writable pipe, but lua-ls can't see that through the helper.
  ---@diagnostic disable-next-line: need-check-nil, undefined-field
  stdin_pipe:write(message)

  return future, id
end

--- Drop the pending entry for a request the caller no longer cares
--- about. Safe to call for an already-resolved id (no-op). Used by
--- bounded waits (e.g. `send_did_change` on TIMEOUT) so a late server
--- reply doesn't resolve a future no one is awaiting; without this the
--- entry survives until the transport dies.
function M.cancel_request(id)
  pending_requests[id] = nil
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
--- proceeding to `run`. Intentionally the same magnitude as the
--- `run_complete` bound in init.lua — both protect against the same
--- failure mode (a server task wedged with neither response nor
--- progress). If you tune one, look at the other.
local DID_CHANGE_TIMEOUT_MS = 2000

--- Outcome of a `send_did_change` call. The caller can log this for
--- diagnosability; the run should proceed in every branch.
local DID_CHANGE = {
  ACKED = "acked", -- server replied with a result
  UNSUPPORTED = "unsupported", -- METHOD_NOT_FOUND (older server)
  ERROR = "error", -- server returned a non-NOT_FOUND error (or the transport died)
  TIMEOUT = "timeout", -- no reply within DID_CHANGE_TIMEOUT_MS
  MALFORMED = "malformed", -- reply has neither result nor error
}
M.DID_CHANGE = DID_CHANGE

--- Send an in-band `did_change` notice to the server for the given file
--- paths and wait (bounded) for the response. Must be called BEFORE the
--- corresponding `run` on the same stdio session — that ordering is what
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
  local future, id = M.send_request("did_change", { paths = paths })

  -- Bounded wait: `future.wait()` would block forever if the server
  -- accepted the request but never replied (slow discovery, swallowed
  -- reply, deadlock). Race the wait against a sleep, exactly like the
  -- `run_complete_event` bound in init.lua. nio.first returns as soon
  -- as either branch completes; it does NOT cancel the loser, so the
  -- `future.wait()` coroutine keeps running and may write to `resp` /
  -- `timed_out` after we return — harmless because we never read them
  -- again, but it does mean the closure stays alive until the server
  -- reply arrives or the transport dies.
  local resp = nil
  local wait_err = nil
  local timed_out = true
  nio.first({
    function()
      -- pcall: the future is failed (set_error) when the server process
      -- exits or is stopped mid-wait. Map that to ERROR, not a crash.
      local ok, r = pcall(future.wait)
      if ok then
        resp = r
      else
        wait_err = r
      end
      timed_out = false
    end,
    function()
      nio.sleep(DID_CHANGE_TIMEOUT_MS)
    end,
  })

  if timed_out then
    -- Drop the pending entry so a late reply doesn't resolve a future
    -- no one is awaiting. Caller (init.lua) restarts the server before
    -- sending `run`: stdio is a single in-order channel, so a `run`
    -- sent behind the still-processing `did_change` would queue behind
    -- it with no second connection to escape to.
    M.cancel_request(id)
    log.warn("server: did_change timed out after", DID_CHANGE_TIMEOUT_MS, "ms — proceeding")
    return DID_CHANGE.TIMEOUT
  end

  if wait_err then
    log.warn("server: did_change transport error —", tostring(wait_err))
    return DID_CHANGE.ERROR
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

--- Bounded liveness probe for the server we spawned earlier this
--- session, sent in-band over the existing stdio session (with stdio
--- there is no side channel — the pipes are the only way in).
---
--- "Bounded" because an unbounded ping wait would hang `ensure_server`
--- forever against a wedged-but-alive server (process running, ping
--- never answered — e.g. a stuck prior run holding `disc.lock`),
--- turning a recoverable failure into a persistent session lockup.
---
--- On timeout the pending entry is cancelled so a late pong can't
--- resolve a future no one is awaiting; `_on_data` drops replies whose
--- id has no pending entry, so the stray line is harmless.
---
--- @param timeout_ms number
--- @return boolean alive
local function probe_alive(timeout_ms)
  local ok, future, id = pcall(M.send_request, "ping")
  if not ok then
    return false
  end

  -- Poll for completion. 50ms granularity is fine for a 1s budget.
  local elapsed = 0
  while not future.is_set() and elapsed < timeout_ms do
    nio.sleep(50)
    elapsed = elapsed + 50
  end

  if not future.is_set() then
    M.cancel_request(id)
    return false
  end

  -- pcall: a failed future (process exited mid-probe) means dead. Any
  -- successful reply — even a JSON-RPC error — is liveness evidence.
  -- Bind to one local so the contract is strictly `boolean` (a bare
  -- `return pcall(...)` would leak the reply value to callers).
  local alive = pcall(future.wait)
  return alive
end

function M.ensure_server(config)
  log.info("server: ensure_server (stdio)")

  -- If a server from earlier this session is still up, reuse it after a
  -- bounded liveness check (see `probe_alive`). An unbounded ping wait
  -- would hang `ensure_server` forever against a wedged-but-alive
  -- server, turning every subsequent test run into a lockup.
  if M.is_running() then
    if probe_alive(1000) then
      log.debug("server: reusing server spawned earlier this session")
      return true
    end
    log.warn("server: process present but not responding — restarting")
    M.stop_server()
  elseif server_process ~= nil then
    -- Process handle exists but the transport is gone (stdin closed) —
    -- reap it before respawning.
    M.stop_server()
  end

  -- Spawn a fresh server wired to our pipes. There is no port to
  -- collide on and no way to piggy-back on someone else's server — the
  -- stdio session belongs exclusively to this nvim process, which also
  -- kills the old "connected to a server for a different project"
  -- failure mode by construction.
  --
  -- "Spawn failed" can mean: binary not on PATH, missing exec
  -- permission, OOM, etc. We let `vim.uv.spawn` fail however it fails,
  -- and surface whatever stderr the spawned process wrote before
  -- exiting.
  local stdin = vim.uv.new_pipe()
  local stdout = vim.uv.new_pipe()
  local stderr = vim.uv.new_pipe()

  local cmd = config.tryke_command or "tryke"
  local server_args, server_env = M._build_spawn_options(config)

  -- Per-spawn, captured only by this process's stderr callback and read
  -- only by this invocation's ready-poll. A module global would let a
  -- slow-to-reap predecessor's late stderr bleed into the next session's
  -- failure message.
  local stderr_chunks = {}
  read_buffer = ""

  -- `exit_code` is set by the on-exit callback iff the process
  -- terminates before our ready-poll succeeds. nil = still running
  -- (or never spawned); non-nil = exited early.
  local exit_code = nil
  local exit_signal = nil

  log.info("server: spawning", cmd, table.concat(server_args, " "))
  -- `own_handle` is captured by the exit callback as an upvalue.
  -- The callback only touches module state when `server_process` still
  -- points at this specific handle. Without that guard, a late exit
  -- callback from a previously-killed server (e.g. after `stop_server`'s
  -- waits timed out and ensure_server already respawned) would
  -- unconditionally erase the new process's handle and fail the new
  -- session's pending requests.
  local own_handle = nil
  own_handle = vim.uv.spawn(cmd, {
    args = server_args,
    env = server_env,
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    log.info("server: process exited code =", code, "signal =", signal)
    exit_code = code
    exit_signal = signal
    -- These pipes belong to this process regardless of whether it is
    -- still the module's current server, so always release them.
    if not stdin:is_closing() then
      stdin:close()
    end
    if not stdout:is_closing() then
      stdout:read_stop()
      stdout:close()
    end
    if not stderr:is_closing() then
      stderr:read_stop()
      stderr:close()
    end
    if server_process == own_handle then
      server_process = nil
      stdin_pipe = nil
      fail_pending(
        string.format("tryke server exited (code=%s, signal=%s)", tostring(code), tostring(signal))
      )
    end
    if own_handle and not own_handle:is_closing() then
      own_handle:close()
    end
  end)

  if not own_handle then
    stdin:close()
    stdout:close()
    stderr:close()
    log.error("server: failed to spawn", cmd)
    error(string.format("failed to spawn `%s` (is it on PATH?)", cmd))
  end

  server_process = own_handle
  stdin_pipe = stdin

  log.debug("server: spawned pid", server_process:get_pid() or "<unknown>")

  stdout:read_start(function(read_err, data)
    -- Ignore output from a process that is no longer the current server.
    -- If `stop_server` timed out and we respawned, a slow-to-reap
    -- predecessor can still deliver bytes here; acting on them would
    -- corrupt the new session's `read_buffer`, resolve its pending
    -- requests against stale replies, or (via `on_transport_lost`) fail
    -- its requests and kill the new server we just started.
    if server_process ~= own_handle then
      return
    end
    if read_err then
      log.warn("server: stdout read error — treating transport as lost:", read_err)
      on_transport_lost("tryke server stdout read error: " .. tostring(read_err), own_handle)
      return
    end
    if not data then
      -- EOF: the server closed stdout. Usually it's on its way out and
      -- the exit callback reaps it, but don't depend on that — no further
      -- replies can arrive on this pipe, so fail pending waiters and make
      -- sure the process gets torn down either way.
      log.debug("server: stdout EOF — transport closed")
      on_transport_lost("tryke server closed stdout", own_handle)
      return
    end
    M._on_data(data)
  end)

  -- Collect stderr so we can include it in the error message if the
  -- spawn fails early. Without this the user sees an unhelpful
  -- "failed to start within timeout" and has to dig through nvim
  -- logs (or run tryke server by hand) to find the actual cause.
  stderr:read_start(function(_, data)
    -- No `own_handle` guard needed: `stderr_chunks` is this spawn's local,
    -- so a predecessor's callback appends to *its* table, not ours — and
    -- guarding on `server_process` would risk dropping this process's last
    -- stderr chunk if it arrives just after the exit callback nils it.
    if data then
      table.insert(stderr_chunks, data)
    end
  end)

  -- Readiness: a single ping, written immediately. Unlike the old TCP
  -- transport there is no connect/retry dance — the OS buffers the
  -- request on the pipe until the server starts reading, so the first
  -- pong IS the ready signal. Poll until it arrives (success) or the
  -- process exits without ever answering (failure with stderr).
  local ready_future, ready_id = M.send_request("ping")
  local timeout = 10000
  local interval = 100
  local elapsed = 0
  while elapsed < timeout do
    nio.sleep(interval)
    elapsed = elapsed + interval

    if exit_code ~= nil then
      -- Process died before becoming ready. Surface its stderr — for a
      -- missing python that's an import error from the runner; etc.
      local stderr_text = table.concat(stderr_chunks)
      log.error("server: exited before ready, code =", exit_code, "signal =", exit_signal)
      error(
        string.format(
          "tryke server exited (code=%s, signal=%s) before becoming ready:\n%s",
          tostring(exit_code),
          tostring(exit_signal),
          stderr_text ~= "" and stderr_text or "<no stderr captured>"
        )
      )
    end

    if ready_future.is_set() then
      -- Set means either a reply arrived (ready) OR the transport failed
      -- the future — `on_transport_lost` (stdout EOF/read error) or the
      -- exit callback both call `fail_pending`. A successful wait is the
      -- ready signal; a failed one means startup died, so abort now with
      -- the underlying reason instead of sleeping out the full timeout and
      -- reporting a misleading "failed to start within timeout".
      local ok, err = pcall(ready_future.wait)
      if ok then
        log.info("server: ready after", elapsed, "ms")
        return true
      end
      log.error("server: transport failed during startup —", tostring(err))
      M.stop_server()
      error("tryke server transport failed during startup: " .. tostring(err))
    end
  end

  log.error("server: failed to start within", timeout, "ms")
  M.cancel_request(ready_id)
  M.stop_server()
  error("tryke server failed to start within timeout")
end

--- Stop escalation bounds. The stdio server's clean-shutdown signal is
--- EOF on its stdin (LSP convention — tryke PR #148); a healthy server
--- exits promptly once its worker pool and FS watcher stop. SIGTERM
--- covers a server that ignores EOF (wedged session task), SIGKILL
--- covers a process that ignores SIGTERM. Each wait watches for the
--- on-exit callback to nil `server_process` — until the OS actually
--- reaps the child we must not consider it gone.
local STOP_EOF_WAIT_MS = 1000
local STOP_SIGTERM_WAIT_MS = 1000
local STOP_SIGKILL_WAIT_MS = 500

--- Block until `pred()` is true or `timeout_ms` elapses, driving the
--- libuv loop so the process on-exit callback can fire meanwhile.
---
--- Which primitive we can use depends on the calling context, and
--- `stop_server` is reachable from several:
---   * Inside an nio task — `ensure_server`'s restart path, the
---     `did_change` timeout path, the neotest `stop` strategy callback.
---     When such a task is resumed *inside* a libuv callback (which is
---     exactly what happens after a `future.wait()` that the stdout
---     reader resolved), it runs in a "fast event context" where
---     `vim.wait` raises E5560. `nio.sleep` is the only safe blocker
---     there — and it works in every nio context.
---   * The `VimLeavePre` autocmd — a synchronous main-loop callback with
---     no nio task running, so `nio.sleep` can't schedule; `vim.wait` is
---     the right (and allowed) primitive.
--- Detect the nio task and pick accordingly.
local function wait_until(pred, timeout_ms)
  if pred() then
    return true
  end
  if nio.current_task() then
    local elapsed = 0
    while not pred() and elapsed < timeout_ms do
      nio.sleep(25)
      elapsed = elapsed + 25
    end
  elseif not vim.in_fast_event() then
    vim.wait(timeout_ms, pred, 25)
  end
  -- No `else`: a raw fast-event caller with no nio task can't block
  -- safely — fall through best-effort (the kill signal was still sent;
  -- reaping just happens after we return).
  return pred()
end

function M.stop_server()
  if server_process and not server_process:is_closing() then
    local pid = server_process:get_pid()

    -- Graceful first: closing stdin delivers EOF, which the server
    -- treats as "client gone" and uses to shut down cleanly.
    if stdin_pipe and not stdin_pipe:is_closing() then
      stdin_pipe:close()
    end
    stdin_pipe = nil

    local function reaped()
      return server_process == nil
    end

    -- WAIT for the on-exit callback to nil `server_process` before each
    -- escalation.
    local exited = wait_until(reaped, STOP_EOF_WAIT_MS)

    if not exited and server_process then
      log.warn("server: EOF didn't stop pid", pid, "— escalating to SIGTERM")
      pcall(function()
        server_process:kill("sigterm")
      end)
      exited = wait_until(reaped, STOP_SIGTERM_WAIT_MS)
    end

    if not exited and server_process then
      log.warn("server: SIGTERM didn't reap pid", pid, "— escalating to SIGKILL")
      pcall(function()
        server_process:kill("sigkill")
      end)
      wait_until(reaped, STOP_SIGKILL_WAIT_MS)
    end
  end

  -- Belt + braces: if the waits timed out (e.g. nvim shutting down,
  -- libuv loop frozen), clear the module state anyway so we don't leak
  -- it — the exit callback's `server_process == own_handle` guard keeps
  -- a late callback from clobbering a respawned server.
  server_process = nil
  if stdin_pipe and not stdin_pipe:is_closing() then
    stdin_pipe:close()
  end
  stdin_pipe = nil
  read_buffer = ""
  fail_pending("tryke server stopped")
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("neotest_tryke_cleanup", { clear = true }),
  callback = function()
    -- The stdio server cannot outlive nvim — its stdin closes when the
    -- editor exits, and EOF is its shutdown signal — so there is no
    -- `auto_stop = false` "leave it running" mode anymore. Stop
    -- explicitly anyway to give it the EOF → SIGTERM → SIGKILL
    -- escalation instead of an abrupt teardown.
    M.stop_server()
  end,
})

return M
