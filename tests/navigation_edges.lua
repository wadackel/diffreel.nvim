vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/sub/deep", "p")
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
  local r = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(r.code == 0, r.stderr)
  return vim.trim(r.stdout)
end
git({ "init", "-qb", "main" })
for _, path in ipairs({ "a", "b", "sub/deep/[literal]" }) do
  vim.fn.writefile({ "old", "same", "old", "same", "old" }, root .. "/" .. path)
end
git({ "add", "." })
git({ "commit", "-qm", "base" })
local base = git({ "rev-parse", "HEAD" })
for _, path in ipairs({ "a", "b", "sub/deep/[literal]" }) do
  vim.fn.writefile({ "new", "same", "new", "same", "new" }, root .. "/" .. path)
end
local function ready(v)
  assert(vim.wait(5000, function()
    return (v.ready and not v.updating) or v.error
  end, 5))
  assert(not v.error, v.error)
end
local failures, passed = {}, 0
local function test(name, body)
  local ok, err = xpcall(body, debug.traceback)
  for _, v in pairs(vim.tbl_extend("force", {}, plugin.views)) do
    plugin.close(v)
  end
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
plugin.setup({ watch = false })
test("single-file root may name a repository subdirectory", function()
  local v = plugin.open({ root = root .. "/sub", file = root .. "/sub/deep/[literal]" })
  ready(v)
  assert(v.selected_path == "sub/deep/[literal]" and v.entries[1].status == "modified")
end)
test("inactive panel placement keeps native diff and current tab", function()
  local v = plugin.open({ root = root })
  ready(v)
  local home = v.return_tab
  vim.api.nvim_set_current_tabpage(home)
  for _, position in ipairs({ "right", "top", "bottom", "left" }) do
    plugin.set_explorer(v, { visible = false })
    plugin.set_explorer(v, { visible = true, position = position, compact = true })
    assert(vim.api.nvim_get_current_tabpage() == home and v.alive)
    for _, win in ipairs({ v.left_win, v.right_win }) do
      vim.api.nvim_win_call(win, function()
        assert(vim.fn.diff_hlID(2, 1) == 0 and vim.fn.diff_hlID(1, 1) > 0, "Explorer polluted native diff")
      end)
    end
  end
end)
test("resizing explicitly reapplies the configured dimension", function()
  local v = plugin.open({ root = root, explorer = { width = 30 } })
  ready(v)
  vim.api.nvim_win_set_width(v.explorer_win, 20)
  plugin.set_explorer(v, { width = 30 })
  assert(vim.api.nvim_win_get_width(v.explorer_win) == 30)
end)
test("layout round trips preserve the diff pane width ratio", function()
  local v = plugin.open({ root = root })
  ready(v)
  local before = vim.api.nvim_win_get_width(v.left_win) / vim.api.nvim_win_get_width(v.right_win)
  for _ = 1, 8 do
    plugin.set_explorer(v, { visible = false })
    local ratio = vim.api.nvim_win_get_width(v.left_win) / vim.api.nvim_win_get_width(v.right_win)
    assert(math.abs(ratio - before) < 0.1, "Hiding the explorer unbalanced the diff panes")
    for _, position in ipairs({ "right", "top", "bottom", "left" }) do
      plugin.set_explorer(v, { visible = true, position = position })
      local moved_ratio = vim.api.nvim_win_get_width(v.left_win) / vim.api.nvim_win_get_width(v.right_win)
      assert(math.abs(moved_ratio - before) < 0.1, "Moving the explorer unbalanced the diff panes: " .. position)
    end
  end
end)
for _, action in ipairs({ "layout", "selection", "close", "leave", "restart", "navigation" }) do
  test("delayed cross-file hunk after " .. action, function()
    local v = plugin.open({ root = root, selected_file = "a" })
    ready(v)
    vim.api.nvim_set_current_win(v.right_win)
    plugin.last_hunk(v)
    local backend, delayed = v.manager.backend, {}
    local request = backend.request
    backend.request = function(self, method, params, done)
      request(self, method, params, function(err, result)
        if method == "blob/read" then
          delayed[#delayed + 1] = function()
            done(err, result)
          end
        else
          done(err, result)
        end
      end)
    end
    plugin.next_hunk(v, 1)
    assert(vim.wait(5000, function()
      return #delayed > 0
    end, 5))
    backend.request = request
    local target
    if action == "layout" then
      plugin.set_explorer(v, { visible = false, position = "bottom" })
    elseif action == "selection" then
      plugin.select(v, "sub/deep/[literal]")
      ready(v)
    elseif action == "close" then
      plugin.close(v)
    elseif action == "leave" then
      vim.api.nvim_set_current_tabpage(v.return_tab)
    elseif action == "restart" then
      backend:close()
      plugin.refresh(v)
      ready(v)
    else
      target = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(target, 0, -1, false, { "target draft" })
      vim.api.nvim_win_set_buf(v.right_win, target)
    end
    for _, deliver in ipairs(delayed) do
      deliver()
    end
    vim.wait(50, function()
      return false
    end, 5)
    if action == "layout" then
      assert(v.selected_path == "b" and v.ready and vim.api.nvim_win_get_cursor(v.right_win)[1] == 1)
    elseif action == "selection" then
      assert(v.selected_path == "sub/deep/[literal]" and v.ready)
    elseif action == "close" then
      assert(not v.alive and not plugin.get_view(v.id))
    elseif action == "navigation" then
      assert(vim.api.nvim_win_get_buf(v.right_win) == target and vim.bo[target].modified)
    end
    assert(not v.pending_hunk, "Stale hunk operation survived")
  end)
end
test("pinned triple-dot and merge-base keep fixed revisions after restart", function()
  git({ "add", "." })
  git({ "commit", "-qm", "second" })
  local second = git({ "rev-parse", "HEAD" })
  local v = plugin.open({
    root = root,
    left = base .. "...HEAD",
    file = "sub/deep/[literal]",
    explorer = { visible = true, position = "bottom", mode = "list" },
  })
  ready(v)
  local same = plugin.open({ root = root, left = base, right = "HEAD", merge_base = true, file = "sub/deep/[literal]" })
  ready(same)
  assert(same.comparison.comparison_id == v.comparison.comparison_id and #v.entries == 1)
  vim.fn.writefile({ "later" }, root .. "/sub/deep/[literal]")
  git({ "add", "." })
  git({ "commit", "-qm", "third" })
  local manager = same.manager
  manager.backend:close()
  plugin.refresh(same)
  ready(same)
  assert(same.manager ~= manager and same.comparison.left == base and same.comparison.right == second)
  assert(vim.api.nvim_buf_get_lines(same.right_buf, 0, 1, false)[1] == "new")
end)
plugin.shutdown()
vim.fn.delete(root, "rf")
for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
