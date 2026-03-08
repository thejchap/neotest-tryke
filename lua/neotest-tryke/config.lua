local M = {}

local defaults = {
  tryke_command = "tryke",
  mode = "direct",
  args = {},
  server = {
    port = 2337,
    host = "127.0.0.1",
    auto_start = true,
    auto_stop = true,
  },
  workers = nil,
  fail_fast = false,
  filter_neotest_python = true,
}

function M.get(user_opts)
  return vim.tbl_deep_extend("force", defaults, user_opts or {})
end

return M
