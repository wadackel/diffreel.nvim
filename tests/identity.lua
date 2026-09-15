vim.opt.rtp:prepend(vim.fn.getcwd())
local data = vim.fn.tempname()
vim.env.XDG_DATA_HOME = data
local daemon = vim.g.diffreel_daemon or vim.env.DIFFREEL_DAEMON
local plugin
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
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
  local result = vim.system(command, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
end

local ok, err = xpcall(function()
  plugin = require("diffreel")
  vim.cmd("runtime plugin/diffreel.lua")
  assert(vim.g.loaded_diffreel)
  for _, suffix in ipairs({ "", "Close", "Refresh", "Install" }) do
    assert(vim.fn.exists(":Diffreel" .. suffix) == 2)
  end
  local dist = require("diffreel.distribution")
  local install = require("diffreel.install")
  assert(dist.protocol == 4 and dist.repository == "github.com/wadackel/diffreel.nvim")
  local spec = dist.current()
  assert(spec.asset == "diffreel-daemon-" .. spec.target and spec.tag == "daemon-" .. spec.id)
  assert(install.path(spec) == data .. "/nvim/diffreel/daemon/" .. spec.id .. "/" .. spec.target)
  assert(not install.cached(spec), "fresh data directory must have no managed daemon")
  vim.g.diffreel_daemon = assert(daemon, "Set DIFFREEL_DAEMON")
  plugin.setup({ watch = false, auto_install = false })
  git({ "init", "-q" })
  vim.fn.writefile({ "base" }, root .. "/a.txt")
  git({ "add", "." })
  git({ "commit", "-qm", "base" })
  vim.fn.writefile({ "changed" }, root .. "/a.txt")
  local events = 0
  vim.api.nvim_create_autocmd("User", {
    pattern = "DiffreelReady",
    callback = function()
      events = events + 1
    end,
  })
  vim.api.nvim_cmd({ cmd = "Diffreel", args = { "--repo", root } }, {})
  local view = plugin.get_current()
  assert(vim.wait(10000, function()
    return view.ready or view.error
  end, 5))
  assert(not view.error, view.error)
  assert(events > 0)
  assert(vim.bo[view.explorer_buf].filetype == "diffreel")
  assert(vim.api.nvim_buf_get_name(view.left_buf):match("^diffreel://"))
  assert(vim.b[view.left_buf].diffreel_path == "a.txt")
  assert(vim.fn.hlexists("DiffreelTitle") == 1)
  plugin.show_help(view)
  assert(vim.bo[view.help.buf].filetype == "diffreel-help")
  plugin.close(view)
end, debug.traceback)
if plugin then
  plugin.shutdown()
end
vim.fn.delete(root, "rf")
vim.fn.delete(data, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
