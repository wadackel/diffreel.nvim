vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(args)
  local cmd = {
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
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ "init", "-qb", "main" })
vim.fn.writefile({ "old", "same", "last", "end" }, root .. "/a.txt")
vim.fn.writefile({ "metadata" }, root .. "/b.txt")
vim.fn.writefile({ "gone", "remain" }, root .. "/c.txt")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile({ "new", "same", "changed", "end" }, root .. "/a.txt")
vim.uv.fs_chmod(root .. "/b.txt", 493)
vim.fn.writefile({ "remain" }, root .. "/c.txt")
local function input(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end
local function settled(view)
  assert(vim.wait(5000, function()
    return view.ready and not view.pending_hunk or view.error
  end, 5))
  assert(not view.error, view.error)
end
local ok, err = xpcall(function()
  plugin.setup({ watch = false })
  local v = plugin.open({ root = root, explorer = { visible = false } })
  settled(v)
  vim.api.nvim_set_current_win(v.right_win)
  input("[H")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
  input("]H")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3)
  input("]h")
  settled(v)
  assert(v.selected_path == "c.txt" and vim.api.nvim_win_get_cursor(0)[1] == 1, "Did not skip metadata-only file")
  vim.fn.setreg('"', "keep")
  input("yih")
  assert(vim.fn.getreg('"') == "keep" and not vim.bo[v.right_buf].modified)
  input("[h")
  settled(v)
  assert(v.selected_path == "a.txt" and vim.api.nvim_win_get_cursor(0)[1] == 3)
  input("[H2yih")
  assert(vim.fn.getreg('"') == "new\nsame\nchanged\n", "Count did not include two hunks")
  input("Vih")
  assert(vim.fn.mode() == "V", "Visual selection was toggled off")
  input("<Esc>3Gdih")
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(v.right_buf, 0, -1, false), { "new", "same", "end" }))
  input("u")
  assert(vim.api.nvim_buf_get_lines(v.right_buf, 2, 3, false)[1] == "changed")
  input("2G")
  vim.fn.setreg('"', "keep")
  input("yih")
  assert(vim.fn.getreg('"') == "keep")
  local selectmode = vim.o.selectmode
  vim.o.selectmode = "cmd"
  input("[Hyih")
  assert(vim.fn.getregtype('"') == "V", "selectmode changed the text object to characterwise")
  input("[HcihNEW<Esc>")
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(v.right_buf, 0, 2, false), { "NEW", "same" }),
    "Change joined an unchanged line"
  )
  input("u")
  vim.o.selectmode = selectmode
  plugin.close(v)
end, debug.traceback)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
