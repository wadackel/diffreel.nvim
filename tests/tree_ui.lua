vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("filetype on")
local plugin = require("diffreel")
local failures, passed, clipboard = {}, 0, nil
vim.g.clipboard = {
  name = "diffreel-tree-ui-fixture",
  copy = {
    ["+"] = function(lines, kind)
      clipboard = { text = table.concat(lines, "\n"), kind = kind }
    end,
    ["*"] = function()
      error("Unexpected clipboard register")
    end,
  },
  paste = {
    ["+"] = function()
      return { { "" }, "v" }
    end,
    ["*"] = function()
      return { { "" }, "v" }
    end,
  },
}
local function input(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end
local function ready(view, path)
  assert(
    vim.wait(5000, function()
      return view.error or (view.ready and not view.updating and (not path or view.selected_path == path))
    end, 5),
    "View did not become ready"
  )
  assert(not view.error, view.error)
end
local function cursor(view, path)
  vim.api.nvim_set_current_win(view.explorer_win)
  for i, row in ipairs(view.rows) do
    if row.path == path then
      vim.api.nvim_win_set_cursor(view.explorer_win, { i + 3, 0 })
      return
    end
  end
  error("Missing tree row: " .. path)
end
local function cursor_path(view)
  local row = view.rows[vim.api.nvim_win_get_cursor(view.explorer_win)[1] - 3]
  return row and row.path
end
local function visible(view, path)
  for _, row in ipairs(view.rows) do
    if row.path == path then
      return row
    end
  end
end
local function test(name, body)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = assert(vim.uv.fs_realpath(root))
  local view
  local function write(path, text)
    local full = root .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    local file = assert(io.open(full, "wb"))
    file:write(text)
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
  local ok, err = xpcall(function()
    git({ "init", "-q" })
    local paths = { "root.lua", "src/a.lua", "src/deep/b.lua", "src/deep/more/c.lua", "src-other/d.lua" }
    for _, path in ipairs(paths) do
      write(path, "return 1\n")
    end
    git({ "add", "." })
    git({ "commit", "-qm", "Baseline" })
    for _, path in ipairs(paths) do
      write(path, "return 2\n")
    end
    plugin.setup({ daemon = vim.env.DIFFREEL_DAEMON, watch = false, keymaps = {} })
    view = plugin.open({ root = root })
    ready(view)
    body({ root = root, view = view, write = write, git = git, paths = paths })
  end, debug.traceback)
  plugin.shutdown()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! enew!")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):sub(1, #root + 1) == root .. "/" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.fn.delete(root, "rf")
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end

test("tree keys and copies preserve the selected diff and do no repository work", function(t)
  local view = t.view
  plugin.select(view, "src/deep/b.lua")
  ready(view, "src/deep/b.lua")
  local buf, left, sequence = view.right_buf, view.left_buf, view.selection_seq
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "draft" })
  assert(vim.wait(1000, function()
    return view.disk_conflict
  end))
  local requests, request = {}, view.manager.backend.request
  view.manager.backend.request = function(self, method, params, done)
    requests[#requests + 1] = method
    return request(self, method, params, done)
  end
  cursor(view, "src/deep/b.lua")
  input("W")
  assert(cursor_path(view) == "src/deep" and view.collapsed["src/deep/more"])
  input("<C-h>")
  assert(cursor_path(view) == "src" and view.collapsed.src)
  input("E")
  assert(not next(view.collapsed) and cursor_path(view) == "src")
  cursor(view, "src/deep")
  input("<C-h><CR>")
  assert(visible(view, "src/deep/more/c.lua"))
  cursor(view, "src/deep/b.lua")
  input("^^^")
  assert(cursor_path(view) == "src")
  cursor(view, "root.lua")
  input("^<C-h>")
  assert(
    cursor_path(view) == "root.lua" and view.root == t.root,
    vim.inspect({ cursor = cursor_path(view), view_root = view.root, root = t.root })
  )
  input("WE")
  assert(cursor_path(view) == "root.lua" and not next(view.collapsed))
  cursor(view, "src/deep/b.lua")
  input("gW")
  assert(cursor_path(view) == "src" and not visible(view, "src/deep/b.lua"))
  input("gE")
  cursor(view, "src/a.lua")
  input("yp")
  assert(clipboard.text == "src/a.lua" and clipboard.kind == "v")
  input("yP")
  assert(clipboard.text == t.root .. "/src/a.lua")
  input("yn")
  assert(clipboard.text == "a.lua")
  assert(view.right_buf == buf and view.left_buf == left and view.selection_seq == sequence)
  assert(view.selected_path == "src/deep/b.lua" and vim.bo[buf].modified)
  assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "draft")
  assert(#requests == 0, vim.inspect(requests))
  assert(vim.api.nvim_get_current_win() == view.explorer_win)
end)

test("automatic refresh and HEAD changes keep folds and reconcile retained entries", function(t)
  local view = t.view
  plugin.select(view, "src/deep/b.lua")
  ready(view, "src/deep/b.lua")
  local buf = view.right_buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "draft" })
  cursor(view, "src/deep/b.lua")
  input("gW")
  cursor(view, "src-other")
  t.write("src/deep/b.lua", "return 3\n")
  plugin.refresh(view)
  ready(view)
  assert(view.collapsed.src and cursor_path(view) == "src-other")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "Advance HEAD" })
  local head = t.git({ "rev-parse", "HEAD" })
  plugin.refresh(view)
  assert(vim.wait(5000, function()
    return view.ready
      and not view.updating
      and view.comparison.left == head
      and view.by_path["src/deep/b.lua"]
      and view.by_path["src/deep/b.lua"].buffer_only
  end, 5))
  assert(view.collapsed.src and view.collapsed["src/deep"] and not view.collapsed["src-other"])
  assert(cursor_path(view) == "src" and not visible(view, "src/deep/b.lua"))
  assert(view.tree.nodes["src/deep/b.lua"].entry == view.by_path["src/deep/b.lua"])
  t.write("new/deep/file.lua", "new\n")
  t.write("src/fresh.lua", "new\n")
  plugin.refresh(view)
  ready(view)
  assert(visible(view, "new/deep/file.lua") and not visible(view, "src/fresh.lua"))
  assert(view.collapsed.src and cursor_path(view) == "src")
  assert(view.right_buf == buf and vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "draft")
end)

test("boundary navigation reveals the file without reloading it", function(t)
  local view = t.view
  local path = view.entries[#view.entries].path
  plugin.select(view, path)
  ready(view, path)
  cursor(view, path)
  input("gW")
  local count, request = 0, view.manager.backend.request
  view.manager.backend.request = function(self, method, params, done)
    count = count + 1
    return request(self, method, params, done)
  end
  local sequence, buf = view.selection_seq, view.right_buf
  input("<Tab>")
  assert(cursor_path(view) == path and visible(view, path))
  assert(sequence == view.selection_seq and buf == view.right_buf and count == 0)
  input("gW")
  vim.api.nvim_set_current_win(view.right_win)
  input("]f")
  assert(cursor_path(view) == path and vim.api.nvim_get_current_win() == view.right_win and count == 0)
  plugin.close(view)
  assert(pcall(plugin.next_file, view, 1))
end)

test("automatic replacement selection stays hidden until explicit navigation", function(t)
  local view = t.view
  plugin.select(view, "root.lua")
  ready(view, "root.lua")
  cursor(view, "src/deep")
  input("gW")
  t.write("root.lua", "return 1\n")
  plugin.refresh(view)
  ready(view)
  assert(view.selected_path ~= "root.lua" and not visible(view, view.selected_path))
  assert(view.collapsed.src and view.collapsed["src-other"] and cursor_path(view) == "src")
  input("<Tab>")
  ready(view)
  assert(visible(view, view.selected_path) and cursor_path(view) == view.selected_path)
end)

test("definition navigation also reconciles folds without stealing the target", function(t)
  local view = t.view
  plugin.select(view, "src/deep/b.lua")
  ready(view, "src/deep/b.lua")
  local source = view.right_buf
  cursor(view, "src/deep")
  input("gW")
  local target = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { "definition" })
  vim.api.nvim_set_current_win(view.right_win)
  vim.api.nvim_win_set_buf(view.right_win, target)
  assert(vim.wait(1000, function()
    return view.navigation
  end))
  t.write("src/deep/more/c.lua", "return 1\n")
  t.write("new/deep/file.lua", "new\n")
  plugin.refresh(view)
  assert(vim.wait(5000, function()
    return not view.updating and view.by_path["new/deep/file.lua"] ~= nil
  end))
  assert(not view.collapsed["src/deep/more"] and view.collapsed.src)
  assert(visible(view, "new/deep/file.lua") and not visible(view, "src/deep/b.lua"))
  assert(vim.api.nvim_win_get_buf(view.right_win) == target)
  vim.api.nvim_win_set_buf(view.right_win, source)
  assert(vim.wait(5000, function()
    return not view.navigation and view.ready
  end))
  assert(view.collapsed.src and not visible(view, "src/deep/b.lua"))
  vim.api.nvim_buf_delete(target, { force = true })
end)

test("delayed selection and retained inspection cannot reopen folded paths", function(t)
  local view = t.view
  local request, hold, held = view.manager.backend.request, "blob/read", nil
  view.manager.backend.request = function(self, method, params, done)
    if method == hold then
      hold = nil
      return request(self, method, params, function(err, value)
        held = function()
          done(err, value)
        end
      end)
    end
    return request(self, method, params, done)
  end
  plugin.select(view, "src/deep/b.lua")
  assert(vim.wait(5000, function()
    return held ~= nil
  end))
  cursor(view, "src/deep/b.lua")
  input("gW")
  held()
  ready(view, "src/deep/b.lua")
  assert(view.collapsed.src and cursor_path(view) == "src")
  vim.api.nvim_buf_set_lines(view.right_buf, 0, -1, false, { "draft" })
  t.write("src/deep/b.lua", "return 1\n")
  hold, held = "comparison/file", nil
  plugin.refresh(view)
  assert(vim.wait(5000, function()
    return held ~= nil
  end))
  input("gE")
  cursor(view, "src/deep")
  input("W")
  held()
  ready(view)
  assert(view.collapsed["src/deep"] and cursor_path(view) == "src/deep")
  assert(view.tree.nodes["src/deep/b.lua"].entry == view.by_path["src/deep/b.lua"])
  assert(view.by_path["src/deep/b.lua"].buffer_only)
end)

test("file-plus-children rows fold without losing file selection or descendants", function(t)
  local view = t.view
  vim.fn.delete(t.root .. "/src", "rf")
  t.write("src", "replacement\n")
  plugin.refresh(view)
  ready(view)
  plugin.select(view, "src")
  ready(view, "src")
  cursor(view, "src")
  local content = vim.api.nvim_buf_get_lines(view.right_buf, 0, -1, false)
  input("<C-h>")
  assert(view.collapsed.src and visible(view, "src").entry and not visible(view, "src/a.lua"))
  input("<CR>")
  ready(view, "src")
  assert(view.collapsed.src and vim.deep_equal(content, vim.api.nvim_buf_get_lines(view.right_buf, 0, -1, false)))
  input("E")
  assert(visible(view, "src/a.lua") and visible(view, "src/deep/more/c.lua"))
  cursor(view, "src/a.lua")
  input("yp")
  assert(clipboard.text == "src/a.lua")
  input("^")
  assert(cursor_path(view) == "src")
end)

test("fold state is independent between reviews and empty trees are safe", function(t)
  local first = t.view
  cursor(first, "src/deep")
  input("W")
  local second = plugin.open({ root = t.root })
  ready(second)
  assert(not next(second.collapsed) and first.collapsed["src/deep"])
  for _, path in ipairs(t.paths) do
    t.write(path, "return 1\n")
  end
  plugin.refresh(second)
  ready(second)
  assert(#second.rows == 0 and not next(second.collapsed))
  local old = clipboard
  input("^<C-h>EWgEgWypyPyn")
  assert(clipboard == old and #second.rows == 0 and second.alive)
end)

test("refresh preserves the explorer cursor column and non-entry rows", function(t)
  local view = t.view
  for i = 1, 40 do
    t.write(("src/scroll-%02d.lua"):format(i), "new\n")
  end
  plugin.refresh(view)
  ready(view)
  cursor(view, "src/scroll-30.lua")
  vim.api.nvim_win_call(view.explorer_win, function()
    vim.cmd("normal! zt")
  end)
  local viewport = vim.api.nvim_win_call(view.explorer_win, vim.fn.winsaveview)
  assert(viewport.topline > 1)
  plugin.refresh(view)
  ready(view)
  local after = vim.api.nvim_win_call(view.explorer_win, vim.fn.winsaveview)
  assert(after.topline == viewport.topline and after.leftcol == viewport.leftcol)
  cursor(view, "src/deep/b.lua")
  local position = vim.api.nvim_win_get_cursor(view.explorer_win)
  position[2] = 8
  vim.api.nvim_win_set_cursor(view.explorer_win, position)
  plugin.refresh(view)
  ready(view)
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(view.explorer_win), position))
  vim.api.nvim_win_set_cursor(view.explorer_win, { 1, 0 })
  plugin.refresh(view)
  ready(view)
  assert(vim.api.nvim_win_get_cursor(view.explorer_win)[1] == 1)
  vim.api.nvim_buf_set_lines(view.right_buf, 0, -1, false, { "draft" })
  assert(vim.wait(1000, function()
    return view.disk_conflict
  end))
  vim.api.nvim_win_set_cursor(view.explorer_win, { vim.api.nvim_buf_line_count(view.explorer_buf), 5 })
  t.write("new-entry.lua", "new\n")
  plugin.refresh(view)
  ready(view)
  local footer = vim.api.nvim_win_get_cursor(view.explorer_win)
  assert(
    vim.trim(vim.api.nvim_buf_get_lines(view.explorer_buf, footer[1] - 1, footer[1], false)[1])
      == "Unsaved buffer differs from disk"
  )
  assert(footer[2] == 5)
end)

test("resizing the explorer updates clipping and status alignment without reads", function(t)
  local view = t.view
  local original = visible(view, "root.lua").text
  local requests, request = 0, view.manager.backend.request
  view.manager.backend.request = function(self, method, params, done)
    requests = requests + 1
    return request(self, method, params, done)
  end
  vim.api.nvim_win_set_width(view.explorer_win, 40)
  vim.api.nvim_exec_autocmds("WinResized", {})
  assert(
    vim.wait(1000, function()
      return visible(view, "root.lua").text ~= original
    end, 5),
    "Explorer rows retained their old width"
  )
  assert(vim.fn.strdisplaywidth(visible(view, "root.lua").text) == 39)
  assert(requests == 0)
end)

test("file navigation follows the complete displayed tree order through folds", function(t)
  local view, ordered = t.view, {}
  for _, row in ipairs(view.rows) do
    if row.entry then
      ordered[#ordered + 1] = row.path
    end
  end
  assert(view.selected_path == ordered[1], "Initial selection skips the first displayed file")
  input("gW")
  for _, path in ipairs(ordered) do
    assert(view.selected_path == path, "Navigation skips the next file in tree order: " .. path)
    plugin.next_file(view)
    ready(view)
  end
  assert(view.selected_path == ordered[#ordered])
  plugin.next_file(view, -2)
  ready(view)
  assert(view.selected_path == ordered[#ordered - 2])
end)

test("reused rows retain selection highlights and current buffer-state messages", function(t)
  local view = t.view
  local path = "src/a.lua"
  plugin.select(view, path)
  ready(view, path)
  local function selected_line()
    local found
    for _, mark in
      ipairs(
        vim.api.nvim_buf_get_extmarks(
          view.explorer_buf,
          vim.api.nvim_create_namespace("diffreel"),
          0,
          -1,
          { details = true }
        )
      )
    do
      if mark[4].line_hl_group == "DiffreelExplorerSelected" then
        assert(not found, "Multiple selected rows remained highlighted")
        assert(vim.fn.strdisplaywidth(mark[4].virt_text[1][1]) == 1, "Selection marker covers the file icon")
        found = mark[2] + 1
      end
    end
    return found
  end
  assert(view.rows[selected_line() - 3].path == path)
  local ambiwidth = vim.o.ambiwidth
  local ok, err = pcall(function()
    vim.o.ambiwidth = "double"
    plugin.refresh(view)
    ready(view)
    assert(view.rows[selected_line() - 3].path == path)
  end)
  vim.o.ambiwidth = ambiwidth
  plugin.refresh(view)
  ready(view)
  assert(ok, err)
  vim.api.nvim_buf_set_lines(view.right_buf, 0, -1, false, { "first draft" })
  assert(vim.wait(1000, function()
    return view.disk_conflict
  end))
  local stable = vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false)
  vim.api.nvim_buf_set_lines(view.right_buf, 0, -1, false, { "second draft" })
  local processed = false
  vim.schedule(function()
    processed = true
  end)
  assert(vim.wait(1000, function()
    return processed
  end))
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false), stable))
  assert(view.rows[selected_line() - 3].path == path)
  vim.api.nvim_buf_set_lines(view.right_buf, 0, -1, false, { "return 2" })
  assert(vim.wait(1000, function()
    return not view.disk_conflict
  end))
  local current = vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false)
  assert(current[#current] ~= "Unsaved buffer differs from disk")
  vim.bo[view.explorer_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.explorer_buf, 3, 4, false, { "external replacement" })
  vim.bo[view.explorer_buf].modifiable = false
  cursor(view, path)
  input("E")
  assert(vim.api.nvim_buf_get_lines(view.explorer_buf, 3, 4, false)[1] == view.rows[1].text)
end)

test("large integer limits reach the daemon without scientific notation", function(t)
  plugin.close(t.view)
  plugin.shutdown()
  plugin.setup({ max_bytes = 1000000000000000, reconcile_ms = 1000000000000000 })
  local view = plugin.open({ root = t.root })
  ready(view)
  assert(#view.entries == #t.paths)
end)

for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
