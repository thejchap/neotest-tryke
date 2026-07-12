local M = {}

local nio = require("nio")
local Tree = require("neotest.types").Tree
local log = require("neotest-tryke.logger")

local function relpath(abs, root)
  if not root then
    return abs
  end
  if abs:sub(1, #root + 1) == root .. "/" then
    return abs:sub(#root + 2)
  end
  return abs
end

local function count_lines(path)
  local f = io.open(path, "r")
  if not f then
    return 0
  end
  local count = 0
  for _ in f:lines() do
    count = count + 1
  end
  f:close()
  return count
end

local source_cache = setmetatable({}, { __mode = "v" })

--- Read a file's lines once and cache the resulting array. Per-case line
--- resolution has to look at every case on the decorator, so reading the
--- file once up-front beats streaming it per case.
---@param path string
---@return string[]
local function read_lines(path)
  local cached = source_cache[path]
  if cached then
    return cached
  end
  local f = io.open(path, "r")
  if not f then
    return {}
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  source_cache[path] = lines
  return lines
end

--- Patterns that identify the *origin line* of a single `@test.cases` case
--- inside a file. `test.case("label", …)` (typed form), `label=` (kwargs
--- form) and `("label", {…})` (list form) each leave a distinctive
--- substring on one line. We require the literal label string — with its
--- quotes, where applicable — so we don't false-positive on test bodies
--- that happen to mention the label somewhere below the decorator.
---@param label string
---@return string[]
local function case_line_patterns(label)
  -- Lua-pattern-escape the label so labels with magic chars (e.g.
  -- "2 + 3") still match literally.
  local escaped = label:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
  return {
    'test%.case%("' .. escaped .. '"',
    "test%.case%('" .. escaped .. "'",
    '%("' .. escaped .. '"%s*,',
    "%('" .. escaped .. "'%s*,",
    "^%s*" .. escaped .. "%s*=",
  }
end

--- Locate the source line that declares the case whose label is *label*.
--- Anchor the search near *start_line* — the decorator's line range is
--- typically within a few dozen lines of the decorated function — so a
--- label that happens to appear in an unrelated test body further down
--- doesn't win. Falls back to `start_line` if nothing matches.
---@param file_path string
---@param label string
---@param start_line number
---@return number
local function find_case_line(file_path, label, start_line)
  local lines = read_lines(file_path)
  if #lines == 0 then
    return start_line
  end
  local patterns = case_line_patterns(label)
  local lo = math.max(1, start_line - 60)
  local hi = math.min(#lines, start_line + 120)
  local best
  for i = lo, hi do
    local line = lines[i]
    for _, pattern in ipairs(patterns) do
      if line:find(pattern) then
        if best == nil or math.abs(i - start_line) < math.abs(best - start_line) then
          best = i
        end
        break
      end
    end
  end
  return best or start_line
end

local function parse_collect_output(stdout)
  local tests = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and decoded and decoded.event == "collect_complete" and decoded.tests then
      for _, t in ipairs(decoded.tests) do
        table.insert(tests, t)
      end
    end
  end
  return tests
end

--- Return the leaf name that tryke uses for matching (`-k`) and for the
--- test-run result keys in `results.build_id`. For parametrized cases it
--- includes the `[label]` suffix; otherwise it's just `test.name`.
local function tryke_leaf(test)
  local label = test.case_label
  if type(label) == "string" and label ~= "" then
    return test.name .. "[" .. label .. "]"
  end
  return test.name
end

local function build_test_position(file_path, test)
  local leaf = tryke_leaf(test)
  local display = test.display_name
  local has_display = type(display) == "string" and display ~= "" and display ~= test.name
  local has_case = type(test.case_label) == "string" and test.case_label ~= ""

  -- For parametrized cases, `line_number` is the decorated function's line
  -- — every case for the same function would otherwise share it and the
  -- sign column would stack all their pass/fail markers on that one line.
  -- Scan the source for the exact `test.case("label", …)` / kwarg / tuple
  -- declaration so each case gets a per-line range.
  local line = test.line_number or 1
  if has_case then
    line = find_case_line(file_path, test.case_label, line)
  end

  local position = {
    type = "test",
    path = file_path,
    range = { line - 1, 0, line - 1, 0 },
  }

  if has_case and has_display then
    -- `@test("basic").cases(case("1+1"), …)` — show "basic[1+1]" so each
    -- case is distinguishable while preserving the function-level label.
    -- `_func_name` carries the runner-facing leaf (`labelled_addition[1+1]`)
    -- so server-mode `to_server_id` continues to match the rust
    -- `TestItem::id()` of `relative::function_name[case_label]`.
    position.name = display .. "[" .. test.case_label .. "]"
    position._func_name = leaf
  elseif has_case then
    position.name = leaf
  elseif has_display then
    position.name = display
    position._func_name = test.name
  else
    position.name = test.name
  end

  if test.doctest_object and test.doctest_object ~= vim.NIL then
    position._is_doctest = true
    -- For doctests tryke sends a `"doctest: X"` display name; preserve it
    -- as the user-facing name and carry the dotted python symbol on
    -- `_func_name` so `-k` filtering lines up with the test runner.
    if type(display) == "string" and display ~= "" then
      position.name = display
      position._func_name = test.name
    end
  end

  return position
end

--- Construct the nested list that `Tree.from_list` expects: a file node
--- at the head, followed by namespace sublists containing child tests /
--- nested namespaces. Namespaces share the file's range so later
--- containment checks don't reject them — the Tree is built structurally
--- here, not by range contains, so the wide range is harmless.
local function build_tree_list(file_path, tests, file_range)
  local file_node = {
    {
      type = "file",
      path = file_path,
      name = vim.fn.fnamemodify(file_path, ":t"),
      range = file_range,
      id = file_path,
    },
  }

  -- Key namespaces by their full group path so we only create each one
  -- once even when tests arrive out of "tree order".
  local sep = "\0"
  local ns_lists = { [""] = file_node }

  for _, test in ipairs(tests) do
    local parent_list = file_node
    local groups = test.groups or {}
    local parent_key = ""
    local id_parts = { file_path }

    for _, group in ipairs(groups) do
      local new_key = parent_key == "" and group or (parent_key .. sep .. group)
      table.insert(id_parts, group)
      local existing = ns_lists[new_key]
      if not existing then
        existing = {
          {
            type = "namespace",
            path = file_path,
            name = group,
            range = file_range,
            id = table.concat(id_parts, "::"),
          },
        }
        table.insert(parent_list, existing)
        ns_lists[new_key] = existing
      end
      parent_list = existing
      parent_key = new_key
    end

    local position = build_test_position(file_path, test)
    local leaf_parts = vim.list_extend({}, id_parts)
    table.insert(leaf_parts, tryke_leaf(test))
    position.id = table.concat(leaf_parts, "::")
    table.insert(parent_list, { position })
  end

  return file_node
end

--- Build a neotest Tree for one file from an already-parsed TestItem
--- list. Returns nil for an empty list (lets neotest treat the file as
--- empty).
---@param file_path string
---@param tests table[]
---@return table|nil
function M.build_file_tree(file_path, tests)
  if #tests == 0 then
    return nil
  end
  local file_range = { 0, 0, count_lines(file_path), 0 }
  local list = build_tree_list(file_path, tests, file_range)
  return Tree.from_list(list, function(pos)
    return pos.id
  end)
end

--- Kill a collect subprocess that wedges rather than exits; well past
--- any observed whole-project collect time.
local COLLECT_TIMEOUT_MS = 15000

--- After a failed whole-project collect, error out immediately (→
--- treesitter fallback) instead of re-spawning a failing batch for every
--- file neotest asks about.
local FAILURE_BACKOFF_S = 10

--- Bound on the server `discover` round-trip. Generous — a warm
--- rediscover is tens of ms — because the wait is async and a slow reply
--- only delays positions, never the UI.
local SERVER_DISCOVER_TIMEOUT_MS = 10000

--- Per-root discovery caches:
---   complete     — a whole-project collect has succeeded; absence from
---                  `by_file` then means "no tests in this file"
---   collected_at — os.time() captured before that collect spawned
---   by_file      — [abs path] = { tests = TestItem[], validated_at }
---   sem          — nio semaphore(1) serializing this root's tryke spawns;
---                  doubles as the single-flight guard for the batch
---                  (waiters re-check the cache after acquiring)
---   failed_at    — os.time() of the last failed batch, for the backoff
local caches = {}

--- Drop every per-root cache. Called from adapter setup — a new config
--- may change `tryke_command`/`python` and invalidate cached results —
--- and from specs.
function M.reset()
  caches = {}
end

local function get_cache(root)
  local cache = caches[root]
  if not cache then
    cache = {
      complete = false,
      collected_at = 0,
      by_file = {},
      sem = nio.control.semaphore(1),
      failed_at = nil,
    }
    caches[root] = cache
  end
  return cache
end

--- Run `fn` while holding the cache's semaphore. Trap errors and rethrow
--- after the release: not every nio version releases on error, and a
--- throw that kept the semaphore would deadlock every later discover for
--- this root.
local function with_lock(cache, fn)
  local ok, err
  cache.sem.with(function()
    ok, err = pcall(fn)
  end)
  if not ok then
    error(err, 0)
  end
end

local function build_cmd(cfg, rel)
  local cmd = { cfg.tryke_command, "test" }
  if rel then
    table.insert(cmd, rel)
  end
  table.insert(cmd, "--collect-only")
  table.insert(cmd, "--reporter")
  table.insert(cmd, "json")
  if cfg.python then
    table.insert(cmd, "--python")
    table.insert(cmd, cfg.python)
  end
  return cmd
end

--- Spawn a tryke collect and await it WITHOUT blocking the editor:
--- `vim.system`'s completion callback resolves an nio future that this
--- coroutine (neotest calls discover_positions from an nio context)
--- yields on. Returns the parsed TestItem list; throws on spawn failure
--- or non-zero exit so callers keep the treesitter-fallback contract.
local function spawn_collect(cmd, cwd)
  log.debug("cli_discover: spawn", table.concat(cmd, " "), "cwd =", cwd)
  local future = nio.control.future()
  local ok, spawn_err = pcall(vim.system, cmd, {
    cwd = cwd,
    text = true,
    timeout = COLLECT_TIMEOUT_MS,
  }, function(result)
    future.set(result)
  end)
  if not ok then
    log.error("cli_discover: vim.system threw for", cmd[1], "—", tostring(spawn_err))
    error("failed to run " .. cmd[1] .. ": " .. tostring(spawn_err))
  end
  local result = future.wait()
  if result.code ~= 0 then
    log.warn("cli_discover: exit", result.code, "stderr:", (result.stderr or ""):sub(1, 500))
    error("tryke --collect-only exited " .. result.code)
  end
  return parse_collect_output(result.stdout)
end

--- Resolve tryke's root-relative `TestItem.file_path` to an absolute
--- path (mirrors `results.build_id`). Absolute paths pass through.
local function abspath(rel, root)
  if rel:sub(1, 1) == "/" then
    return rel
  end
  return root .. "/" .. rel
end

--- Freshness stamp for a collect that started at `started_at` (wall
--- seconds). Freshness is checked as `mtime < validated_at`, so a file
--- whose last modification predates the collect — the collect saw its
--- current content — gets `mtime + 1` and stays fresh until the next
--- save bumps its mtime. A file modified during the collect keeps the
--- conservative `started_at` stamp: the next lookup treats it as stale
--- and re-collects.
local function freshness_stamp(path, started_at)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.mtime.sec < started_at then
    return stat.mtime.sec + 1
  end
  return started_at
end

--- Install a whole-project TestItem list as this root's cache snapshot.
local function install_project_tests(cache, root, tests, started_at)
  local by_file = {}
  for _, t in ipairs(tests) do
    local fp = t.file_path
    if type(fp) == "string" and fp ~= "" then
      local abs = abspath(fp, root)
      local entry = by_file[abs]
      if not entry then
        entry = { tests = {}, validated_at = freshness_stamp(abs, started_at) }
        by_file[abs] = entry
      end
      table.insert(entry.tests, t)
    end
  end
  cache.by_file = by_file
  cache.collected_at = started_at
  cache.complete = true
  cache.failed_at = nil
end

--- One whole-project collect for the root: ~the same cost as collecting
--- a single file (discovery is static Rust-side parsing), and it replaces
--- one spawn per test file during neotest's project-wide scan.
local function run_batch_collect(cache, root, cfg)
  local started_at = os.time()
  local ok, tests = pcall(spawn_collect, build_cmd(cfg, nil), root)
  if not ok then
    cache.failed_at = os.time()
    error(tests, 0)
  end
  log.debug("cli_discover: batch →", #tests, "test(s) for", root)
  install_project_tests(cache, root, tests, started_at)
end

--- Collect just `file_path` (stale or unknown to the snapshot). An empty
--- result is still a valid entry: the file genuinely has no tests.
local function collect_single_file(cache, file_path, root, cfg)
  local started_at = os.time()
  local tests = spawn_collect(build_cmd(cfg, relpath(file_path, root)), root)
  log.debug("cli_discover:", file_path, "→", #tests, "test(s)")
  for _, t in ipairs(tests) do
    log.trace(
      "cli_discover: test name =",
      t.name,
      "groups =",
      t.groups,
      "case_label =",
      t.case_label,
      "line =",
      t.line_number
    )
  end
  cache.by_file[file_path] = {
    tests = tests,
    validated_at = freshness_stamp(file_path, started_at),
  }
end

--- Refresh the snapshot through the persistent tryke server instead of a
--- one-shot CLI spawn. Only when the adapter runs in server mode AND the
--- server is already up — discovery must never pay server cold-start;
--- the one-shot batch is cheaper than spawning workers. Returns false on
--- any failure so the caller falls through to the CLI path.
local function server_refresh(cache, root, cfg, changed_path)
  if not cfg or cfg.mode ~= "server" then
    return false
  end
  local server = require("neotest-tryke.server")
  if not server.is_running() then
    return false
  end
  if changed_path then
    -- The server learns of saves via its debounced FS watcher; an
    -- immediate `discover` could return pre-save results. `did_change`
    -- first, so the warm discoverer sees the file as dirty. pcall: the
    -- transport may die between `is_running` and the write.
    pcall(server.send_did_change, { changed_path })
  end
  local started_at = os.time()
  local resp, outcome = server.request_with_timeout("discover", nil, SERVER_DISCOVER_TIMEOUT_MS)
  if outcome ~= server.RPC.OK then
    log.debug("cli_discover: server discover", outcome, "— falling back to one-shot CLI")
    return false
  end
  local tests = resp and resp.result and resp.result.tests
  if type(tests) ~= "table" then
    log.warn("cli_discover: server discover result has no tests array")
    return false
  end
  log.debug("cli_discover: server discover →", #tests, "test(s)")
  install_project_tests(cache, root, tests, started_at)
  return true
end

--- Discover tests in `file_path` by delegating to tryke.
--- Returns a `neotest.Tree` on success, or `nil` if tryke reports no
--- tests (lets neotest treat the file as empty).
---
--- neotest's project-wide scan calls this once per test file; instead of
--- one subprocess per call (203 spawns ≈ seconds of overhead on large
--- projects), the first call fills a per-root snapshot — via the running
--- tryke server's `discover` RPC in server mode, or one whole-project
--- `--collect-only` spawn — and later calls are served from it. Entries
--- are validated against the file's mtime; a stale or unknown file gets
--- a targeted refresh. Every subprocess wait is async (nio), so the UI
--- never blocks.
---
--- Throws if tryke fails (and on repeated batch failures within the
--- backoff window) — the caller catches this and falls back to the
--- treesitter path so a missing binary doesn't take down every
--- discover_positions call.
---@param file_path string
---@param root string|nil  Project root; nil skips the cache and collects
---  the one file, preserving the standalone-file semantics.
---@param cfg table  Resolved adapter config; uses `tryke_command`,
---  `python` (forwarded as `--python <path>` so collection uses the same
---  interpreter as the test run) and `mode`.
---@return table|nil
function M.discover(file_path, root, cfg)
  if not root then
    return M.build_file_tree(file_path, spawn_collect(build_cmd(cfg, file_path), nil))
  end

  local cache = get_cache(root)
  local stat = vim.uv.fs_stat(file_path)
  local mtime = stat and stat.mtime.sec or nil

  --- The cache entry for this file, or nil when it is missing or the
  --- file changed after the collect that produced it. An unstattable
  --- file (specs use paths that exist only in canned output) can't be
  --- mtime-checked — serve whatever the snapshot has.
  local function fresh_entry()
    local entry = cache.by_file[file_path]
    if not entry then
      return nil
    end
    if mtime and mtime >= entry.validated_at then
      return nil
    end
    return entry
  end

  local entry = fresh_entry()

  -- No snapshot yet: fill it once. Concurrent callers (neotest scans
  -- with a worker pool) queue on the semaphore and find the cache
  -- populated when they get in.
  if not entry and not cache.complete then
    with_lock(cache, function()
      if fresh_entry() or cache.complete then
        return
      end
      if cache.failed_at and os.time() - cache.failed_at < FAILURE_BACKOFF_S then
        error("tryke collect failed " .. (os.time() - cache.failed_at) .. "s ago — backing off")
      end
      if not server_refresh(cache, root, cfg, nil) then
        run_batch_collect(cache, root, cfg)
      end
    end)
    entry = fresh_entry()
  end

  if not entry then
    -- Absent from a complete snapshot and unchanged since it was taken:
    -- tryke genuinely found no tests in this file.
    if cache.by_file[file_path] == nil and mtime and mtime < cache.collected_at then
      return nil
    end
    -- Stale, or new since the snapshot: targeted refresh.
    with_lock(cache, function()
      if fresh_entry() then
        return
      end
      if not server_refresh(cache, root, cfg, file_path) then
        collect_single_file(cache, file_path, root, cfg)
      end
    end)
    entry = cache.by_file[file_path]
  end

  if not entry or #entry.tests == 0 then
    return nil
  end
  return M.build_file_tree(file_path, entry.tests)
end

return M
