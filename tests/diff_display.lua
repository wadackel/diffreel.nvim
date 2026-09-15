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
local plugin, view
local ok, err = xpcall(function()
  git({ "init", "-q" })
  vim.fn.writefile({ "removed" }, root .. "/a.txt")
  local original = { "unchanged header", "before" }
  for i = 1, 45 do
    original[#original + 1] = "unchanged line " .. i
  end
  vim.fn.writefile(original, root .. "/b.txt")
  vim.fn.writefile({ "unrelated", "before" }, root .. "/c.txt")
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  vim.fn.delete(root .. "/a.txt")
  local modified = vim.deepcopy(original)
  modified[2] = "after"
  vim.fn.writefile(modified, root .. "/b.txt")
  vim.fn.writefile({ "unrelated", "after" }, root .. "/c.txt")
  plugin = require("diffreel")
  plugin.setup({ backend = "rust", watch = false })
  view = plugin.open({ root = root })
  assert(vim.wait(5000, function()
    return view.ready
  end, 5))
  assert(view.selected_path == "a.txt")
  for _, path in ipairs({ "b.txt", "c.txt", "b.txt" }) do
    plugin.select(view, path)
    assert(vim.wait(5000, function()
      return view.ready and view.selected_path == path
    end, 5))
    for _, win in ipairs({ view.left_win, view.right_win }) do
      vim.api.nvim_win_call(win, function()
        assert(vim.fn.diff_hlID(1, 1) == 0, "An unchanged line belongs to the diff after switching to " .. path)
        assert(vim.fn.diff_hlID(2, 1) ~= 0, "The actual change is missing")
        if path == "b.txt" then
          assert(vim.fn.foldclosed(25) ~= -1, "Unchanged context did not fold")
        end
      end)
    end
  end
  local source = view.right_buf
  local target = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { "unrelated definition" })
  vim.api.nvim_set_current_win(view.right_win)
  vim.api.nvim_win_set_buf(view.right_win, target)
  assert(vim.wait(1000, function()
    return view.navigation
  end, 5))
  assert(not vim.wo[view.right_win].diff, "Definition target remains in the comparison")
  vim.api.nvim_win_set_buf(view.right_win, source)
  assert(vim.wait(1000, function()
    return view.ready and not view.navigation
  end, 5))
  assert(vim.api.nvim_win_call(view.right_win, function()
    return vim.fn.diff_hlID(1, 1)
  end) == 0, "Definition target leaked into the resumed comparison")
  vim.fn.writefile({ "removed" }, root .. "/a.txt")
  vim.fn.writefile(original, root .. "/b.txt")
  vim.fn.writefile({ "unrelated", "before" }, root .. "/c.txt")
  plugin.refresh(view)
  assert(vim.wait(1000, function()
    return view.ready and #view.entries == 0
  end, 5))
  vim.fn.writefile({ "unrelated", "after" }, root .. "/c.txt")
  plugin.refresh(view)
  assert(vim.wait(1000, function()
    return view.ready and view.selected_path == "c.txt"
  end, 5))
  assert(vim.api.nvim_win_call(view.right_win, function()
    return vim.fn.diff_hlID(1, 1)
  end) == 0, "An empty comparison retained its previous buffer")
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
