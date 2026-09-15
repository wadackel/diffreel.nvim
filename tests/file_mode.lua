vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
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
git({ "init", "-q", "-b", "main" })
vim.fn.writefile({ "base", "same" }, root .. "/a.txt")
vim.fn.writefile({ "*.tmp" }, root .. "/.gitignore")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile({ "other" }, root .. "/other.txt")
vim.fn.writefile({ "ignored" }, root .. "/[literal].tmp")
local function ready(view)
  assert(
    vim.wait(5000, function()
      return view.ready or view.error
    end, 5),
    "No ready view"
  )
  assert(not view.error, view.error)
  return view
end
local ok, err = xpcall(function()
  plugin.setup({ watch = false, paths = { "not-this-file" }, exclude = { "**" }, untracked = false })
  vim.cmd.edit(vim.fn.fnameescape(root .. "/a.txt"))
  local clean = ready(plugin.open({ file = true }))
  assert(clean.selected_path == "a.txt" and #clean.entries == 1 and clean.entries[1].status == "unchanged")
  assert(not clean.explorer_win and #vim.api.nvim_tabpage_list_wins(clean.tab) == 2)
  assert(vim.bo[clean.right_buf].buftype == "")
  plugin.close(clean)
  vim.api.nvim_cmd({ cmd = "Diffreel", args = { "--file=" .. root .. "/[literal].tmp", "--stat", "--explorer" } }, {})
  local ignored = ready(plugin.get_current())
  assert(#ignored.entries == 1 and ignored.selected_path == "[literal].tmp" and ignored.explorer_win)
  assert(vim.wait(5000, function()
    return ignored.statistics and ignored.statistics.complete
  end, 5))
  assert(ignored.statistics.files["[literal].tmp"].additions == 1)
  local id = ignored.comparison.comparison_id
  local manager = ignored.manager
  manager.backend:close()
  plugin.refresh(ignored)
  assert(vim.wait(5000, function()
    return ignored.manager ~= manager and ignored.ready and not ignored.updating
  end, 5))
  assert(ignored.comparison.comparison_id == id and #ignored.entries == 1)
  plugin.close(ignored)
  local missing = ready(plugin.open({ root = root, file = "new.txt" }))
  assert(missing.file_missing and missing.entries[1].status == "missing")
  plugin.close(missing)
  vim.cmd.edit(vim.fn.fnameescape(root .. "/new.txt"))
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved new file" })
  local draft = vim.api.nvim_get_current_buf()
  local unsaved = ready(plugin.open({ file = true }))
  assert(unsaved.right_buf == draft and not unsaved.file_missing and vim.bo[draft].modified)
  plugin.close(unsaved)
  assert(vim.bo[draft].modified)
  assert(not pcall(plugin.open, { root = root, file = "../outside" }))
end, debug.traceback)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
