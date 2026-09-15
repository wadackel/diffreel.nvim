vim.opt.rtp:prepend(vim.fn.getcwd())
local options = require("diffreel.options")
local parsed = options.parse({ "--pr=12", "--stat", "--list", "--", "src" })
assert(parsed.pr == "12" and parsed.line_stats and parsed.explorer.mode == "list")
local normalized = options.normalize(parsed)
assert(normalized.pr == "12" and normalized.right ~= "worktree" and not normalized.untracked)
assert(options.parse({ "--pr", "https://github.com/example/project/pull/12" }).pr:find("pull/12", 1, true))
for _, input in ipairs({
  { pr = 0 },
  { pr = -1 },
  { pr = 1.5 },
  { pr = true },
  { pr = "" },
  { pr = "a\0b" },
  { pr = 1, left = "HEAD" },
  { pr = 1, right = "worktree" },
  { pr = 1, merge_base = true },
  { pr = 1, untracked = false },
}) do
  assert(not pcall(options.normalize, input), vim.inspect(input))
end
for _, args in ipairs({ { "--pr=1", "--staged" }, { "--pr=1", "HEAD" }, { "--pr" } }) do
  assert(not pcall(function()
    options.normalize(options.parse(args))
  end), vim.inspect(args))
end
local executable = vim.fn.executable
local tabs, buffers = #vim.api.nvim_list_tabpages(), #vim.api.nvim_list_bufs()
vim.fn.executable = function(name)
  return name == "gh" and 0 or executable(name)
end
local opened = pcall(require("diffreel").open, { root = vim.fn.getcwd(), pr = 1 })
vim.fn.executable = executable
assert(not opened and #vim.api.nvim_list_tabpages() == tabs and #vim.api.nvim_list_bufs() == buffers)
print(vim.json.encode({ passed = true }))
vim.cmd("qa!")
