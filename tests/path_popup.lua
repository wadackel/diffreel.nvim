vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local root = vim.fn.tempname()
local branch = string.rep("long-directory-", 5)
local name = "line\nname.txt"
vim.fn.mkdir(root .. "/" .. branch .. "/nested", "p")
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
git({ "init", "-q" })
vim.fn.writefile({ "base" }, root .. "/" .. branch .. "/nested/" .. name)
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.delete(root .. "/" .. branch .. "/nested/" .. name)
local ok, err = xpcall(function()
  plugin.setup({ watch = false })
  local view = plugin.open({ root = root, explorer = { compact = true } })
  assert(vim.wait(5000, function()
    return view.ready or view.error
  end, 5))
  assert(not view.error, view.error)
  local selected = view.selected_path
  vim.api.nvim_win_set_cursor(view.explorer_win, { 4, 0 })
  vim.api.nvim_feedkeys("K", "xt", false)
  assert(
    view.path_popup
      and vim.api.nvim_buf_get_lines(view.path_popup.buf, 0, 1, false)[1] == view.root .. "/" .. branch .. "/nested"
  )
  assert(vim.wo[view.path_popup.win].wrap and view.selected_path == selected)
  local buf = view.path_popup.buf
  vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "xt", false)
  assert(not view.path_popup and not vim.api.nvim_buf_is_valid(buf) and view.alive)
  vim.api.nvim_win_set_cursor(view.explorer_win, { 5, 0 })
  vim.api.nvim_feedkeys("K", "xt", false)
  assert(
    vim.api.nvim_buf_get_lines(view.path_popup.buf, 0, 1, false)[1]
      == require("diffreel.explorer").display(view.root .. "/" .. selected)
  )
  buf = view.path_popup.buf
  plugin.set_explorer(view, { visible = false })
  assert(not view.path_popup and not vim.api.nvim_buf_is_valid(buf))
  plugin.show_path(view)
  assert(view.path_popup)
  assert(not vim.wo[view.path_popup.win].diff, "Path popup joined the native diff")
  buf = view.path_popup.buf
  plugin.close(view)
  assert(not vim.api.nvim_buf_is_valid(buf))
end, debug.traceback)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
