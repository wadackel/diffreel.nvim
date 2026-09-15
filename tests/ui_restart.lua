vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function write(value)
  local file = assert(io.open(root .. "/main.lua", "wb"))
  file:write("return " .. value .. "\n")
  file:close()
end
local function git(args)
  local command = {
    "git",
    "-c",
    "user.name=Example",
    "-c",
    "user.email=example@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=/dev/null",
  }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = root }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local plugin, view
local ok, err = xpcall(function()
  git({ "init", "-q" })
  write(1)
  git({ "add", "." })
  git({ "commit", "-qm", "one" })
  local base = git({ "rev-parse", "HEAD" })
  write(2)
  git({ "add", "." })
  git({ "commit", "-qm", "two" })
  plugin = require("diffreel")
  plugin.setup({ backend = "rust", watch = false })
  view = plugin.open({ root = root, left = "HEAD~1" })
  assert(vim.wait(5000, function()
    return view.ready
  end, 5))
  local session = view.manager.session_id
  view.manager.backend:close()
  write(3)
  git({ "add", "." })
  git({ "commit", "-qm", "three" })
  plugin.refresh(view)
  assert(vim.wait(5000, function()
    return view.ready
      and not view.updating
      and view.manager.session_id ~= session
      and vim.api.nvim_buf_get_lines(view.right_buf, 0, 1, false)[1] == "return 3"
  end, 5))
  assert(view.comparison.left == base, "Retry re-resolved a fixed revision expression")
  assert(vim.api.nvim_buf_get_lines(view.left_buf, 0, 1, false)[1] == "return 1")
end, debug.traceback)
if view then
  plugin.close(view)
end
if plugin then
  plugin.shutdown()
end
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
