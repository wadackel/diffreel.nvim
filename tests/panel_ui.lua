vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src/deep", "p")
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
for _, path in ipairs({ "src/deep/a", "src/deep/b", "top" }) do
  vim.fn.writefile({ "before", "same" }, root .. "/" .. path)
end
git({ "add", "." })
git({ "commit", "-qm", "base" })
for _, path in ipairs({ "src/deep/a", "src/deep/b", "top" }) do
  vim.fn.writefile({ "after", "same" }, root .. "/" .. path)
end
local function ready(view)
  assert(vim.wait(5000, function()
    return view.ready or view.error
  end, 5))
  assert(not view.error, view.error)
end
local function metrics(view)
  local result
  view.manager.backend:request("debug/metrics", {}, function(err, value)
    assert(not err, vim.inspect(err))
    result = value
  end)
  assert(vim.wait(5000, function()
    return result ~= nil
  end, 5))
  return result.git_spawns
end
local ok, err = xpcall(function()
  plugin.setup({ watch = false, explorer = { status_icons = { added = "+", modified = "~" } } })
  local view = plugin.open({
    root = root,
    selected_file = "src/deep/a",
    explorer = { visible = false, status_icons = { modified = "変更" } },
  })
  ready(view)
  assert(view.explorer_win == nil and #vim.api.nvim_tabpage_list_wins(view.tab) == 2)
  local left, right, draft = view.left_win, view.right_win, view.right_buf
  vim.api.nvim_buf_set_lines(draft, 0, 1, false, { "draft" })
  local before, generation = metrics(view), view.comparison.generation
  plugin.set_explorer(view, { visible = true, compact = true })
  assert(view.explorer_win and #view.rows == 4 and view.rows[1].path == "src/deep")
  local function marker()
    local row = view.rows[#view.rows]
    local line = vim.api.nvim_buf_get_lines(view.explorer_buf, #view.rows + 2, #view.rows + 3, false)[1]
    assert(line == row.text, "Explorer buffer did not update its status icon")
    return row.text:sub(row.marker_col + 1)
  end
  assert(marker() == "変更")
  assert(view.explorer_options.status_icons.added == "+")
  local override = { status_icons = { modified = "[M]" } }
  plugin.set_explorer(view, override)
  assert(marker() == "[M]")
  override.status_icons.modified = "mutated"
  assert(view.explorer_options.status_icons.modified == "[M]")
  assert(plugin.config.explorer.status_icons.modified == "~")
  assert(view.explorer_options.status_icons.added == "+")
  local settings, rows = vim.deepcopy(view.explorer_options), view.rows
  assert(not pcall(plugin.set_explorer, view, { status_icons = { modified = "\n" } }))
  assert(vim.deep_equal(settings, view.explorer_options) and view.rows == rows)
  local tabs = vim.api.nvim_list_tabpages()
  assert(not pcall(plugin.open, { root = root, explorer = { status_icons = { modified = "" } } }))
  assert(vim.deep_equal(tabs, vim.api.nvim_list_tabpages()))
  local panel = view.explorer_win
  vim.api.nvim_win_set_cursor(panel, { 5, 2 })
  for _, position in ipairs({ "bottom", "right", "top", "left" }) do
    plugin.set_explorer(view, { position = position })
    assert(view.explorer_win == panel, "Moving the panel recreated its window")
    local p, l, r =
      vim.api.nvim_win_get_position(panel), vim.api.nvim_win_get_position(left), vim.api.nvim_win_get_position(right)
    if position == "left" then
      assert(p[2] < l[2] and p[2] < r[2])
    elseif position == "right" then
      assert(p[2] > l[2] and p[2] > r[2])
    elseif position == "top" then
      assert(p[1] < l[1] and p[1] < r[1])
    else
      assert(p[1] > l[1] and p[1] > r[1])
    end
    assert(view.left_win == left and view.right_win == right and view.right_buf == draft)
    assert(vim.bo[draft].modified and vim.api.nvim_buf_get_lines(draft, 0, 1, false)[1] == "draft")
  end
  plugin.set_explorer(view, { mode = "list" })
  assert(#view.rows == 3 and view.rows[1].text:find("src/deep/a", 1, true))
  plugin.toggle_explorer(view)
  assert(not view.explorer_win and view.alive)
  plugin.next_file(view, 1)
  ready(view)
  assert(view.selected_path == "src/deep/b")
  plugin.focus_explorer(view)
  assert(vim.api.nvim_get_current_win() == view.explorer_win)
  plugin.toggle_explorer(view)
  assert(not view.explorer_win and vim.api.nvim_get_current_win() == view.right_win)
  plugin.toggle_explorer(view)
  assert(vim.api.nvim_get_current_win() == view.explorer_win, "Toggle did not restore explorer focus")
  vim.api.nvim_set_current_win(view.right_win)
  plugin.toggle_explorer(view)
  plugin.toggle_explorer(view)
  assert(view.explorer_win and vim.api.nvim_get_current_win() == view.right_win, "Toggle moved diff focus")
  vim.api.nvim_set_current_win(view.explorer_win)
  plugin.toggle_explorer(view)
  plugin.focus_explorer(view)
  vim.api.nvim_set_current_win(view.right_win)
  plugin.set_explorer(view, { visible = false })
  plugin.toggle_explorer(view)
  assert(view.explorer_win and vim.api.nvim_get_current_win() == view.right_win, "Another show kept a toggle focus")
  plugin.focus_explorer(view)
  assert(view.explorer_options.mode == "list")
  assert(view.comparison.generation == generation and metrics(view) == before, "Layout changes performed Git work")
  plugin.toggle_explorer(view)
  vim.api.nvim_set_current_tabpage(view.return_tab)
  plugin.toggle_explorer(view)
  assert(view.explorer_win and vim.api.nvim_get_current_tabpage() == view.return_tab, "Toggle switched tabs")
  vim.api.nvim_set_current_tabpage(view.tab)
  assert(vim.api.nvim_get_current_win() == view.right_win and view.explorer_refocus == nil)
  local layout = vim.fn.winlayout()
  assert(not pcall(plugin.set_explorer, view, { position = "invalid" }))
  assert(vim.deep_equal(layout, vim.fn.winlayout()))
  plugin.set_explorer(view, { visible = false })
  local open_win = vim.api.nvim_open_win
  vim.api.nvim_open_win = function()
    error("fixture panel failure")
  end
  local shown = pcall(plugin.set_explorer, view, { visible = true })
  vim.api.nvim_open_win = open_win
  assert(not shown and view.alive and not view.explorer_win)
  plugin.focus_explorer(view)
  assert(view.explorer_win)
  vim.api.nvim_win_close(view.explorer_win, true)
  assert(
    vim.wait(5000, function()
      return not view.alive
    end, 5),
    "Native panel close was mistaken for intentional hide"
  )
  assert(vim.bo[draft].modified)
end, debug.traceback)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
