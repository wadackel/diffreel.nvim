vim.opt.rtp:prepend(vim.fn.getcwd())
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
  local result = vim.system(command, { cwd = root }):wait()
  assert(result.code == 0, result.stderr)
end
local function numbered(name, count)
  local lines = {}
  for i = 1, count do
    lines[i] = name .. " " .. i
  end
  return lines
end
local plugin, view
local ok, err = xpcall(function()
  git({ "init", "-q" })
  for _, name in ipairs({ "a.txt", "b.txt" }) do
    vim.fn.writefile(numbered(name, 300), root .. "/" .. name)
  end
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  for _, name in ipairs({ "a.txt", "b.txt" }) do
    local lines = numbered(name, 300)
    for i = 5, 300, 5 do
      lines[i] = "changed " .. i
    end
    vim.fn.writefile(lines, root .. "/" .. name)
  end
  plugin = require("diffreel")
  plugin.setup({ backend = "rust", watch = false })
  view = plugin.open({ root = root })
  local function select(path)
    vim.api.nvim_set_current_win(view.explorer_win)
    plugin.select(view, path)
    assert(vim.wait(5000, function()
      return view.ready
        and view.selected_path == path
        and (view.layout ~= "inline" or require("diffreel.inline").current(view))
    end, 5))
  end
  local function scroll(win, row)
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({ lnum = row, col = 0, topline = row - 5 })
    end)
  end
  local function position(win)
    local saved = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    return { saved.lnum, saved.topline, saved.topfill }
  end
  local function at_start(label)
    for _, win in ipairs(require("diffreel.windows").visible_windows(view)) do
      local pos = position(win)
      assert(vim.deep_equal(pos, { 1, 1, 0 }), label .. ": " .. vim.inspect(pos))
    end
  end
  assert(vim.wait(5000, function()
    return view.ready
  end, 5))
  local function use_layout(mode)
    plugin.set_layout(view, mode)
    assert(vim.wait(5000, function()
      return view.ready and view.layout == mode and (mode ~= "inline" or require("diffreel.inline").current(view))
    end, 5))
  end
  local function refreshed(check)
    local sequence = view.selection_seq
    plugin.refresh(view)
    assert(vim.wait(5000, function()
      return view.ready and not view.updating and view.selection_seq > sequence and check()
    end, 5))
  end
  for _, mode in ipairs({ "side_by_side", "stacked", "inline" }) do
    use_layout(mode)
    select("a.txt")
    scroll(view.right_win, 250)
    select("b.txt")
    at_start(mode .. " right scrolled")
    if mode ~= "inline" then
      scroll(view.left_win, 200)
    end
    scroll(view.right_win, 200)
    select("a.txt")
    at_start(mode .. " revisit")
    select("b.txt")
    at_start(mode .. " revisit remembered")
  end
  use_layout("side_by_side")
  select("a.txt")
  scroll(view.left_win, 200)
  scroll(view.right_win, 200)
  use_layout("inline")
  select("b.txt")
  use_layout("side_by_side")
  at_start("returning from inline after switching files")

  scroll(view.left_win, 200)
  scroll(view.right_win, 200)
  local changed = {}
  for _, name in ipairs({ "a.txt", "b.txt" }) do
    changed[name] = vim.fn.readfile(root .. "/" .. name)
    vim.fn.writefile(numbered(name, 300), root .. "/" .. name)
  end
  refreshed(function()
    return view.selected_path == nil
  end)
  vim.fn.writefile(changed["b.txt"], root .. "/b.txt")
  refreshed(function()
    return view.selected_path == "b.txt"
  end)
  at_start("reappearing after an empty comparison")

  scroll(view.left_win, 200)
  scroll(view.right_win, 200)
  local before = position(view.right_win)
  local lines = vim.fn.readfile(root .. "/b.txt")
  table.insert(lines, 1, "inserted")
  vim.fn.writefile(lines, root .. "/b.txt")
  refreshed(function()
    return view.selected_path == "b.txt"
  end)
  assert(vim.deep_equal(position(view.right_win), before), "Refreshing the same file moved the viewport")
  assert(position(view.left_win)[2] > 1, "Refreshing the same file reset the baseline viewport")
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
