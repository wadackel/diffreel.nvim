vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.clipboard = {
  name = "diffreel-failing-command-fixture",
  copy = { ["+"] = { "false" }, ["*"] = { "false" } },
  paste = { ["+"] = { "false" }, ["*"] = { "false" } },
  cache_enabled = 0,
}
local notices = {}
vim.notify = function(message)
  notices[#notices + 1] = message
end
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "header", "baseline", "", "missing.lua" })
vim.api.nvim_win_set_cursor(0, { 4, 0 })
local view = {
  root = "/missing",
  explorer_win = vim.api.nvim_get_current_win(),
  rows = { { path = "missing.lua", name = "missing.lua" } },
}
local keys = require("diffreel.keymaps")
local bindings = keys.bindings(
  keys.resolve({ defaults = false, explorer = { X = "yank_path" } }).explorer,
  {},
  function() end
)
bindings.X(view, 1)
assert(vim.v.shell_error == 1, "Fixture did not exercise a failing command provider")
assert(#notices == 0, "A failed clipboard command was announced as a successful copy")
assert(vim.fn.execute("messages"):find("clipboard: error", 1, true), "Native clipboard diagnostic was lost")
vim.api.nvim_buf_delete(buf, { force = true })
print(vim.json.encode({ passed = true }))
