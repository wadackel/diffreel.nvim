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
    plugin.setup({
      daemon = vim.env.DIFFREEL_DAEMON,
      watch = false,
      keymaps = {},
      spinner = require("diffreel.spinner").defaults,
    })
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

local function loading_icon()
  return require("diffreel.ui").icon(nil, "loading")
end
local function spinner_glyph(text)
  for _, candidate in ipairs(require("diffreel.spinner").defaults.frames) do
    if text:find(candidate, 1, true) then
      return candidate
    end
  end
end
local function explorer_text(view)
  return table.concat(vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false), "\n")
end
local function status_text(view)
  local state = view.status
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return ""
  end
  return table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
end
local function waiting_text(view)
  return explorer_text(view) .. "\n" .. status_text(view)
end

test("progress labels carry a spinner frame while work is in flight", function(t)
  local view = t.view
  assert(not spinner_glyph(waiting_text(view)), "Quiescent explorer showed a spinner frame")
  plugin.refresh(view)
  local updating = waiting_text(view)
  assert(view.updating, "refresh did not mark the view as updating")
  assert(not explorer_text(view):find("Updating…", 1, true), "Updating… stayed in the explorer buffer")
  assert(status_text(view):find("Updating…", 1, true), status_text(view))
  assert(spinner_glyph(updating), "Updating label had no spinner frame: " .. updating)
  assert(
    not updating:find(loading_icon(), 1, true),
    "The static loading icon was drawn beside the spinner: " .. updating
  )
  ready(view)
  assert(not spinner_glyph(waiting_text(view)), "Spinner frame survived the update")
  local second = plugin.open({ root = t.root })
  local winbar = vim.wo[second.left_win].winbar
  assert(spinner_glyph(winbar), "Loading winbar had no spinner frame: " .. winbar)
  assert(not winbar:find(loading_icon(), 1, true), "The static loading icon was drawn beside the spinner: " .. winbar)
  ready(second)
  assert(not spinner_glyph(vim.wo[second.left_win].winbar))
  plugin.close(second)
end)

test("every waiting label in a review shows the same frame", function(t)
  require("diffreel.spinner").stop()
  local second = plugin.open({ root = t.root })
  local winbar = spinner_glyph(vim.wo[second.left_win].winbar)
  local body = spinner_glyph(explorer_text(second))
  local overlay = spinner_glyph(status_text(second))
  assert(winbar and body and overlay, "A waiting review had no spinner glyph: " .. waiting_text(second))
  assert(winbar == body, "The winbar and the explorer disagreed: " .. winbar .. " vs " .. body)
  assert(winbar == overlay, "The winbar and the overlay disagreed: " .. winbar .. " vs " .. overlay)
  ready(second)
  plugin.close(second)
end)

test("a disabled spinner leaves the progress labels static", function(t)
  local view = t.view
  plugin.setup({ spinner = false })
  plugin.refresh(view)
  local updating = waiting_text(view)
  assert(updating:find("Updating…", 1, true), updating)
  assert(not spinner_glyph(updating), "Disabled spinner still rendered a frame: " .. updating)
  assert(updating:find(loading_icon(), 1, true), "Disabled spinner lost the static loading icon: " .. updating)
  ready(view)
end)

local function pump()
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  assert(
    vim.wait(1000, function()
      return drained
    end),
    "Event loop did not drain"
  )
end
local function capture_timer(start)
  local state, real = {}, vim.uv.new_timer
  -- The backend also creates timers inside the same call; only the spinner repeats.
  vim.uv.new_timer = function()
    local handle
    handle = {
      start = function(_, delay, period, callback)
        if period > 0 then
          state.delay, state.period, state.tick, state.handle = delay, period, callback, handle
        end
      end,
      stop = function() end,
      is_closing = function()
        return handle.closed == true
      end,
      close = function()
        handle.closed = true
      end,
    }
    return handle
  end
  local ok, err = pcall(start)
  vim.uv.new_timer = real
  assert(ok, err)
  return state
end
local function timer_closed(state)
  return state.handle ~= nil and state.handle.closed == true
end
-- Withholding a single method is not enough to keep a view loading: the daemon
-- answers fast enough that the state can resolve inside one event-loop turn.
local function freeze(view)
  local backend, held, holding = view.manager.backend, {}, true
  local request = backend.request
  backend.request = function(self, name, params, done)
    return request(self, name, params, function(failure, result)
      if holding then
        held[#held + 1] = function()
          done(failure, result)
        end
      else
        done(failure, result)
      end
    end)
  end
  return function()
    holding = false
    backend.request = request
    for _, replay in ipairs(held) do
      replay()
    end
  end
end
local function marks(view)
  return #vim.api.nvim_buf_get_extmarks(view.explorer_buf, vim.api.nvim_create_namespace("diffreel"), 0, -1, {})
end

test("the shared timer advances every progress label without disturbing the explorer", function(t)
  local view, frames = t.view, require("diffreel.spinner").defaults.frames
  local release = freeze(view)
  require("diffreel.spinner").stop()
  cursor(view, "src/a.lua")
  local path = cursor_path(view)
  local timer = capture_timer(function()
    plugin.refresh(view)
  end)
  assert(timer.tick, "Refresh did not start the spinner timer")
  assert(timer.delay == 80 and timer.period == 80, "Timer is not repeating: " .. vim.inspect(timer))
  local viewport = vim.api.nvim_win_call(view.explorer_win, vim.fn.winsaveview)
  local baseline, seen = marks(view), {}
  local initial = spinner_glyph(waiting_text(view))
  assert(initial, "Updating label had no spinner glyph: " .. waiting_text(view))
  seen[initial] = true
  for index = 1, #frames - 1 do
    timer.tick()
    pump()
    local text = waiting_text(view)
    local glyph = spinner_glyph(text)
    assert(glyph, "Frame " .. index .. " lost its spinner glyph: " .. text)
    assert(text:find("Updating…", 1, true), text)
    seen[glyph] = true
    assert(marks(view) == baseline, "Extmark count drifted on frame " .. index)
  end
  assert(vim.tbl_count(seen) == #frames, "Frames did not advance: " .. vim.inspect(seen))
  assert(cursor_path(view) == path, "A frame moved the explorer cursor")
  assert(
    vim.deep_equal(viewport, vim.api.nvim_win_call(view.explorer_win, vim.fn.winsaveview)),
    "A frame moved the explorer viewport"
  )
  release()
  ready(view)
  timer.tick()
  pump()
  assert(timer_closed(timer), "Timer was not closed once no view was loading")
  assert(not spinner_glyph(waiting_text(view)), "Spinner glyph survived the update")
end)

test("a pending selection spins the diff winbar", function(t)
  local view, frames = t.view, require("diffreel.spinner").defaults.frames
  local release = freeze(view)
  require("diffreel.spinner").stop()
  local timer = capture_timer(function()
    plugin.select(view, "src/deep/b.lua")
  end)
  assert(not view.ready, "select did not clear the ready flag")
  assert(timer.tick, "A pending selection did not start the spinner timer")
  local initial = spinner_glyph(vim.wo[view.left_win].winbar)
  assert(initial, "Loading winbar had no spinner glyph: " .. vim.wo[view.left_win].winbar)
  local seen = { [initial] = true }
  for index = 1, #frames - 1 do
    timer.tick()
    pump()
    local winbar = vim.wo[view.left_win].winbar
    local glyph = spinner_glyph(winbar)
    assert(glyph, "Frame " .. index .. " lost the winbar glyph: " .. winbar)
    assert(winbar:find("Loading ", 1, true), winbar)
    seen[glyph] = true
  end
  assert(vim.tbl_count(seen) == #frames, "Winbar frames did not advance: " .. vim.inspect(seen))
  release()
  ready(view, "src/deep/b.lua")
  assert(not spinner_glyph(vim.wo[view.left_win].winbar), "Winbar glyph survived the selection")
end)

test("a view in another tabpage is not redrawn but keeps the timer alive", function(t)
  local view = t.view
  local second = plugin.open({ root = t.root })
  ready(second)
  assert(second.tab ~= view.tab, "The second review did not open in its own tabpage")
  local release = freeze(second)
  require("diffreel.spinner").stop()
  local timer = capture_timer(function()
    plugin.refresh(second)
  end)
  assert(timer.tick, "Refresh did not start the spinner timer")
  vim.api.nvim_set_current_tabpage(view.tab)
  local changes = vim.api.nvim_buf_get_changedtick(second.explorer_buf)
  for _ = 1, 3 do
    timer.tick()
    pump()
  end
  assert(vim.api.nvim_buf_get_changedtick(second.explorer_buf) == changes, "A hidden review was redrawn by the spinner")
  assert(not timer_closed(timer), "The timer stopped while a hidden review was still loading")
  release()
  ready(second)
  plugin.close(second)
end)

test("a stopped review does not animate the saved-line counter", function(t)
  local second = plugin.open({ root = t.root, left = "no-such-revision", line_stats = true })
  assert(
    vim.wait(5000, function()
      return second.error ~= nil
    end, 5),
    "The review did not report an error"
  )
  local before = waiting_text(second)
  assert(before:find("Update stopped", 1, true), before)
  assert(not spinner_glyph(before), "A stopped review rendered a spinner glyph: " .. before)
  vim.wait(400, function()
    return false
  end)
  assert(waiting_text(second) == before, "A stopped review kept redrawing:\n" .. waiting_text(second))
  plugin.close(second)
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
  assert(view.footer_rows[footer[1]].id == "conflict")
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

local function fill_explorer(t, count)
  for i = 1, count do
    t.write(string.format("filler/f%03d.lua", i), "return 2\n")
  end
  plugin.refresh(t.view)
  ready(t.view)
end

test("the status overlay covers the explorer's bottom text rows", function(t)
  local view, status = t.view, require("diffreel.status")
  fill_explorer(t, 60)
  vim.api.nvim_set_current_win(view.explorer_win)
  local count = vim.api.nvim_buf_line_count(view.explorer_buf)
  -- G alone can leave topline short of the bottom, which makes botline a useless reference row.
  vim.api.nvim_win_call(view.explorer_win, function()
    local height = vim.fn.getwininfo(view.explorer_win)[1].height
    vim.fn.winrestview({ lnum = count, col = 0, topline = math.max(1, count - height + 1) })
  end)
  vim.cmd("redraw")
  local parts = {
    { text = " Updating…", group = "DiffreelExplorerLoading" },
    { text = "  still working", group = "DiffreelExplorerLoading" },
  }
  status.update(view, parts)
  vim.cmd("redraw")
  local state = view.status
  assert(state and state.win and vim.api.nvim_win_is_valid(state.win), "The overlay window was not created")
  assert(status.owns(state.win), "The overlay did not claim its window")
  local info = vim.fn.getwininfo(view.explorer_win)[1]
  local bottom = vim.fn.screenpos(view.explorer_win, info.botline, 1).row
  local float = vim.fn.getwininfo(state.win)[1]
  assert(info.botline == count, ("The explorer did not scroll to its last line: %d"):format(info.botline))
  assert(
    float.winrow + #parts - 1 == bottom,
    ("Overlay ended at screen row %d, explorer bottom text row is %d"):format(float.winrow + #parts - 1, bottom)
  )
  assert(float.width == info.width - info.textoff, ("Overlay width %d vs %d"):format(float.width, info.width))
  assert(
    vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)[1] == " Updating…",
    vim.inspect(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
  )
  status.close(view)
  assert(not view.status.win, "close() left the overlay window recorded")
  status.dispose(view)
  assert(view.status == nil, "dispose() left overlay state behind")
end)

test("the explorer reserves no gutter unless statuscolumn is set", function(t)
  local view = t.view
  vim.cmd("redraw")
  assert(vim.fn.getwininfo(view.explorer_win)[1].textoff == 0, "The explorer reserved a gutter by default")
  vim.wo[view.explorer_win].statuscolumn = "%l "
  vim.cmd("redraw")
  local offset = vim.fn.getwininfo(view.explorer_win)[1].textoff
  vim.wo[view.explorer_win].statuscolumn = ""
  assert(offset > 0, "statuscolumn did not reserve a gutter, so col = textoff is untested")
end)

local function overlay_height(view)
  local state = view.status
  if not state or not state.win or not vim.api.nvim_win_is_valid(state.win) then
    return 0
  end
  return vim.api.nvim_win_get_height(state.win)
end

test("the pinned rows leave the explorer buffer and reserve their own space", function(t)
  local view = t.view
  local before = vim.api.nvim_buf_line_count(view.explorer_buf)
  plugin.refresh(view)
  assert(view.updating, "refresh did not mark the view as updating")
  local height = overlay_height(view)
  assert(height == 1, "The overlay did not take exactly the Updating… row: " .. height)
  local lines = vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false)
  assert(not table.concat(lines, "\n"):find("Updating…", 1, true), "Updating… stayed in the explorer buffer")
  for index = #lines - height + 1, #lines do
    assert(lines[index] == "", "Padding row " .. index .. " was not blank: " .. lines[index])
  end
  assert(#lines == before + height, ("Line count %d, expected %d"):format(#lines, before + height))
  for _, id in ipairs({ "updating", "paused", "paused_hint", "error", "retry", "stats_pending" }) do
    for _, part in pairs(view.footer_rows) do
      assert(part.id ~= id, "Pinned id stayed in footer_rows: " .. id)
    end
  end
  assert(
    vim.api.nvim_get_option_value("scrolloff", { win = view.explorer_win }) >= height,
    "scrolloff did not reserve the overlay rows"
  )
  ready(view)
  assert(overlay_height(view) == 0, "The overlay outlived the update")
  assert(vim.api.nvim_buf_line_count(view.explorer_buf) == before, "Padding survived the update")
end)

test("a long tree keeps its last row above the pinned overlay", function(t)
  local view = t.view
  fill_explorer(t, 60)
  vim.api.nvim_set_current_win(view.explorer_win)
  plugin.refresh(view)
  local height = overlay_height(view)
  assert(height > 0, "The overlay was not shown while updating")
  local count = vim.api.nvim_buf_line_count(view.explorer_buf)
  vim.api.nvim_win_call(view.explorer_win, function()
    local window = vim.fn.getwininfo(view.explorer_win)[1].height
    vim.fn.winrestview({ lnum = count - height, col = 0, topline = math.max(1, count - window + 1) })
  end)
  vim.cmd("redraw")
  local info = vim.fn.getwininfo(view.explorer_win)[1]
  local last = #view.rows + 3
  local float = vim.fn.getwininfo(view.status.win)[1]
  assert(vim.fn.screenpos(view.explorer_win, last, 1).row < float.winrow, "The last tree row sat under the overlay")
  assert(info.botline >= last, "The last tree row was not reachable: " .. info.botline)
  ready(view)
end)

test("the overlay is released with the panel, the layout and the review", function(t)
  local view, status = t.view, require("diffreel.status")
  plugin.refresh(view)
  assert(overlay_height(view) > 0, "The overlay was not shown while updating")
  plugin.set_explorer(view, { visible = false })
  assert(overlay_height(view) == 0, "Hiding the panel left the overlay open")
  plugin.set_explorer(view, { visible = true })
  ready(view)
  local win = view.explorer_win
  local saved = vim.api.nvim_get_option_value("scrolloff", { win = win })
  plugin.refresh(view)
  assert(
    vim.api.nvim_get_option_value("scrolloff", { win = win }) >= overlay_height(view),
    "scrolloff did not reserve the overlay rows"
  )
  ready(view)
  assert(
    vim.api.nvim_get_option_value("scrolloff", { win = win }) == saved and view.explorer_win == win,
    "scrolloff was not restored on the same window"
  )
  plugin.refresh(view)
  local overlay = view.status and view.status.win
  assert(overlay and status.owns(overlay), "The overlay window was not claimed")
  ready(view)
  plugin.close(view)
  assert(not overlay or not vim.api.nvim_win_is_valid(overlay), "Closing the review left the overlay window open")
end)

test("a waiting review keeps its overlay inside its own tabpage", function(t)
  local view = t.view
  local second = plugin.open({ root = t.root })
  ready(second)
  assert(second.tab ~= view.tab, "The second review did not open in its own tabpage")
  vim.api.nvim_set_current_tabpage(second.tab)
  plugin.refresh(view)
  assert(view.updating, "refresh did not mark the first review as updating")
  local state = view.status
  if state and state.win and vim.api.nvim_win_is_valid(state.win) then
    assert(
      vim.api.nvim_win_get_tabpage(state.win) == view.tab,
      "A waiting review drew its overlay in the tabpage being viewed"
    )
  end
  vim.api.nvim_set_current_tabpage(view.tab)
  vim.api.nvim_exec_autocmds("TabEnter", { modeline = false })
  assert(
    vim.wait(1000, function()
      return overlay_height(view) > 0
    end, 5),
    "Returning to the review's tabpage did not bring its overlay back"
  )
  ready(view)
  assert(overlay_height(view) == 0, "The overlay outlived the update")
  plugin.close(second)
end)

test("a stopped review keeps its pinned message across a tabpage round trip", function(t)
  local view = t.view
  local second = plugin.open({ root = t.root, left = "no-such-revision" })
  assert(
    vim.wait(5000, function()
      return second.error ~= nil
    end, 5),
    "The review did not report an error"
  )
  assert(status_text(second):find("Update stopped", 1, true), status_text(second))
  vim.api.nvim_set_current_tabpage(view.tab)
  vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
  vim.wait(200, function()
    return false
  end)
  vim.api.nvim_set_current_tabpage(second.tab)
  vim.api.nvim_exec_autocmds("TabEnter", { modeline = false })
  assert(
    vim.wait(1000, function()
      return status_text(second):find("Update stopped", 1, true) ~= nil
    end, 5),
    "A stopped review lost its pinned message after a tabpage round trip: " .. explorer_text(second)
  )
  plugin.close(second)
end)

test("the reserved rows below the tree stay blank and hold no message", function(t)
  local view = t.view
  plugin.refresh(view)
  local height = overlay_height(view)
  assert(height > 0, "The overlay was not shown while updating")
  local lines = vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false)
  local content = #lines - height
  for index = content + 1, #lines do
    assert(lines[index] == "", "A reserved row carried text: " .. lines[index])
    assert(view.footer_rows[index] == nil, "A reserved row was registered as a footer message")
  end
  ready(view)
  local after = vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false)
  assert(#after == content, ("Reserved rows survived the update: %d vs %d"):format(#after, content))
end)

test("a pane too short for the pinned block keeps the whole message in the buffer", function(t)
  local second = plugin.open({ root = t.root, left = "no-such-revision" })
  assert(
    vim.wait(5000, function()
      return second.error ~= nil
    end, 5),
    "The review did not report an error"
  )
  assert(overlay_height(second) > 0, "The overlay was not shown for a stopped review")
  assert(status_text(second):find("R: retry", 1, true), status_text(second))
  local before = vim.api.nvim_buf_line_count(second.explorer_buf)
  plugin.set_explorer(second, { position = "bottom", height = 4 })
  assert(
    vim.wait(1000, function()
      return require("diffreel.status").capacity(second.explorer_win) < 2
    end, 5),
    "The pane did not shrink below the pinned block"
  )
  plugin.refresh(second)
  vim.wait(200, function()
    return false
  end)
  local text = explorer_text(second)
  assert(overlay_height(second) == 0, "The overlay stayed open in a pane too short for it")
  assert(text:find("Update stopped", 1, true), "The cause left the buffer when the overlay was skipped: " .. text)
  assert(text:find("R: retry", 1, true), "The retry hint was dropped when the overlay was skipped: " .. text)
  local lines = vim.api.nvim_buf_get_lines(second.explorer_buf, 0, -1, false)
  assert(lines[#lines] ~= "", "Reserved rows were added even though the overlay was skipped")
  assert(before > 0)
  plugin.close(second)
end)

for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
