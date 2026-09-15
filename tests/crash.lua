vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local original_system, pid = vim.system, nil
local plugin, view
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
  local result = original_system(command, { cwd = root }):wait()
  assert(result.code == 0, result.stderr)
end
local ok, err = xpcall(function()
  git({ "init", "-q" })
  vim.fn.writefile({ "baseline" }, root .. "/a.txt")
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  vim.fn.writefile({ "changed" }, root .. "/a.txt")
  vim.system = function(command, ...)
    local process = original_system(command, ...)
    if command[1]:find("diffreel-daemon", 1, true) then
      pid = process.pid
    end
    return process
  end
  plugin = require("diffreel")
  plugin.setup({ backend = "rust", daemon = vim.env.DIFFREEL_DAEMON, watch = false })
  view = plugin.open({ root = root })
  assert(vim.wait(5000, function()
    return view.ready
  end, 5))
  local session = view.manager.session_id
  assert(pid)
  assert(vim.uv.kill(pid, 9) == 0)
  assert(
    vim.wait(5000, function()
      return view.error ~= nil
    end, 5),
    "Crash did not reach UI"
  )
  assert(vim.api.nvim_buf_get_lines(view.left_buf, 0, 1, false)[1] == "baseline")
  plugin.refresh(view)
  assert(
    vim.wait(5000, function()
      return view.ready and not view.error and not view.updating and view.manager.session_id ~= session
    end, 5),
    "Crash retry did not recover"
  )
end, debug.traceback)
if view then
  plugin.close(view)
end
if plugin then
  plugin.shutdown()
end
vim.system = original_system
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
