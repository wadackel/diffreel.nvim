vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src", "p")
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
  return vim.trim(result.stdout)
end
git({ "init", "-q" })
vim.fn.writefile({ "before", "same" }, root .. "/src/file.lua")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile({ "after", "same" }, root .. "/src/file.lua")
local function ready(view)
  assert(vim.wait(5000, function()
    return view.ready or view.error
  end, 5))
  assert(not view.error, view.error)
end
local function bar(win)
  return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = 100 }).str
end
local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local ok, err = xpcall(function()
  local input = { commit = "%C", worktree = "W", warning = "!", help = "K", path = "P", directory_open = "O" }
  plugin.setup({ watch = false, ui_icons = input })
  local view = plugin.open({ root = root, explorer = { width = 46 } })
  ready(view)
  assert(view.ui_icons.commit == "%C")
  assert(bar(view.left_win):find("%C HEAD · ", 1, true))
  assert(bar(view.right_win):find("W Worktree", 1, true))
  assert(bar(view.explorer_win):find(" Changes", 1, true) and not bar(view.explorer_win):find("files", 1, true))
  assert(text(view.explorer_buf):find(" ", 1, true))
  assert(view.rows[1].text:find("O src", 1, true))
  local source = view.right_buf
  vim.api.nvim_buf_set_lines(source, 0, 1, false, { "draft" })
  assert(vim.wait(1000, function()
    return view.disk_conflict and bar(view.right_win):find(" Unsaved", 1, true)
  end))
  local warning_row, warning_col
  for row, part in pairs(view.footer_rows) do
    if part.id == "conflict" then
      warning_row, warning_col = row, assert(part.text:find("differs", 1, true)) - 1
    end
  end
  vim.api.nvim_win_set_cursor(view.explorer_win, { warning_row, warning_col })
  plugin.set_explorer(view, { width = 18 })
  local cursor = vim.api.nvim_win_get_cursor(view.explorer_win)
  local part = view.footer_rows[cursor[1]]
  assert(part.id == "conflict" and part.text:sub(cursor[2] + 1, cursor[2] + 7) == "differs")
  for _, row in pairs(view.footer_rows) do
    assert(vim.fn.strdisplaywidth(row.text) <= 18)
  end
  plugin.set_explorer(view, { width = 46 })
  vim.api.nvim_win_set_cursor(view.explorer_win, { 5, 0 })
  plugin.show_help(view)
  local help_win, help_buf = view.help.win, view.help.buf
  assert(vim.api.nvim_win_get_config(help_win).title[1][1]:find("K Explorer keys", 1, true))
  assert(text(help_buf):find("Show help", 1, true) and not text(help_buf):find("show_help", 1, true))
  plugin.setup({ ui_icons = { help = "NEW", commit = "NEW", warning = "NEW" } })
  input.commit = "mutated"
  assert(view.ui_icons.commit == "%C" and view.help.win == help_win and view.help.buf == help_buf)
  assert(vim.api.nvim_win_get_config(help_win).title[1][1]:find("K Explorer keys", 1, true))
  vim.api.nvim_feedkeys("q", "xt", false)
  assert(not view.help and vim.api.nvim_get_current_win() == view.explorer_win)
  plugin.show_path(view)
  assert(vim.api.nvim_win_get_config(view.path_popup.win).title[1][1]:find("P Full path", 1, true))
  assert(vim.api.nvim_buf_get_lines(view.path_popup.buf, 0, 1, false)[1] == view.root .. "/src/file.lua")
  vim.api.nvim_feedkeys("q", "xt", false)
  plugin.set_explorer(view, { visible = false })
  plugin.set_explorer(view, { visible = true })
  assert(bar(view.left_win):find("%C HEAD · ", 1, true))
  for _, mode in ipairs({ "stacked", "inline", "side_by_side" }) do
    plugin.set_layout(view, mode)
    assert(vim.wait(5000, function()
      return view.layout == mode and view.ready and not view.inline_pending
    end, 5))
    assert(bar(view.right_win):find(" Unsaved", 1, true))
    assert(view.right_buf == source and vim.bo[source].modified)
  end
  view.error = "fixture update failure"
  plugin.set_explorer(view, { width = 45 })
  assert(bar(view.left_win):find(" Update stopped: fixture update failure", 1, true))
  view.error = nil
  plugin.set_explorer(view, { width = 46 })
  for row, fragment in pairs(view.footer_rows) do
    if fragment.id == "conflict" then
      vim.api.nvim_win_set_cursor(view.explorer_win, { row, fragment.prefix })
      break
    end
  end
  vim.api.nvim_buf_call(source, function()
    vim.cmd.write()
  end)
  assert(vim.wait(1000, function()
    return not view.disk_conflict
  end))
  assert(vim.api.nvim_win_get_cursor(view.explorer_win)[1] > #view.rows + 3)
  vim.api.nvim_buf_set_lines(source, 0, 1, false, { "new draft" })
  local next_view = plugin.open({ root = root, left = git({ "rev-parse", "HEAD" }), explorer = { visible = false } })
  ready(next_view)
  assert(next_view.ui_icons.commit == "NEW" and next_view.ui_icons.worktree == "W")
  assert(bar(next_view.left_win):find("NEW ", 1, true) and not bar(next_view.left_win):find("HEAD", 1, true))
  plugin.close(next_view)
  plugin.close(view)
  assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == "new draft")
  local unborn_root = root .. "/unborn"
  vim.fn.mkdir(unborn_root)
  git({ "-C", unborn_root, "init", "-q" })
  vim.fn.writefile({ "first file" }, unborn_root .. "/first.txt")
  local unborn = plugin.open({ root = unborn_root })
  ready(unborn)
  assert(bar(unborn.left_win):find("HEAD · Empty tree", 1, true))
  assert(vim.api.nvim_buf_get_lines(unborn.explorer_buf, 1, 2, false)[1]:find("HEAD", 1, true))
  plugin.close(unborn)
end, debug.traceback)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
