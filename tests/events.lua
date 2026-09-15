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
vim.fn.writefile({ "old", "same" }, root .. "/a.txt")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile({ "new", "same" }, root .. "/a.txt")
vim.fn.writefile({ "other" }, root .. "/b.txt")
local events = {}
local group = vim.api.nvim_create_augroup("test_diffreel_events", { clear = true })
vim.api.nvim_create_autocmd("User", {
  group = group,
  pattern = "Diffreel*",
  callback = function(e)
    events[#events + 1] = { name = e.match, data = vim.deepcopy(e.data) }
    assert(type(e.data.view_id) == "string" and type(e.data.root) == "string")
    if e.match == "DiffreelClose" then
      assert(plugin.get_view(e.data.view_id) == nil)
    else
      assert(plugin.get_view(e.data.view_id))
    end
  end,
})
local function names(id)
  local result = {}
  for _, event in ipairs(events) do
    if event.data.view_id == id then
      result[#result + 1] = event.name
    end
  end
  return result
end
local function ready(v)
  assert(vim.wait(5000, function()
    return v.ready or v.error
  end, 5))
  assert(not v.error, v.error)
end
local ok, err = xpcall(function()
  plugin.setup({ watch = false })
  local home = vim.api.nvim_get_current_tabpage()
  local v = plugin.open({ root = root })
  ready(v)
  local initial = names(v.id)
  assert(
    vim.deep_equal(initial, {
      "DiffreelOpen",
      "DiffreelEnter",
      "DiffreelDiffBufRead",
      "DiffreelDiffBufRead",
      "DiffreelFileSelect",
      "DiffreelReady",
    }),
    vim.inspect(initial)
  )
  vim.api.nvim_set_current_win(v.right_win)
  assert(#names(v.id) == #initial, "Pane focus emitted a tab event")
  plugin.set_explorer(v, { visible = false })
  assert(names(v.id)[#names(v.id)] == "DiffreelLayoutChanged")
  local count = #names(v.id)
  plugin.set_explorer(v, { visible = false })
  assert(#names(v.id) == count, "No-op layout emitted an event")
  vim.api.nvim_set_current_tabpage(home)
  assert(names(v.id)[#names(v.id)] == "DiffreelLeave")
  vim.api.nvim_set_current_tabpage(v.tab)
  assert(names(v.id)[#names(v.id)] == "DiffreelEnter")
  plugin.select(v, "b.txt")
  ready(v)
  local selected
  for _, e in ipairs(events) do
    if e.name == "DiffreelFileSelect" and e.data.path == "b.txt" then
      selected = e.data
    end
  end
  assert(selected and selected.previous_path == "a.txt")
  plugin.close(v)
  local all = names(v.id)
  assert(all[#all] == "DiffreelClose" and all[#all - 1] == "DiffreelLeave")
  local closer = vim.api.nvim_create_autocmd("User", {
    pattern = "DiffreelOpen",
    callback = function(e)
      plugin.close(plugin.get_view(e.data.view_id))
    end,
  })
  local closed = plugin.open({ root = root })
  assert(not closed.alive and not closed.manager, "Open hook resurrected the view")
  vim.api.nvim_del_autocmd(closer)
  local once = true
  local selector = vim.api.nvim_create_autocmd("User", {
    pattern = "DiffreelDiffBufRead",
    callback = function(e)
      if once then
        once = false
        plugin.select(plugin.get_view(e.data.view_id), "b.txt")
      end
    end,
  })
  local changed = plugin.open({ root = root })
  ready(changed)
  assert(changed.selected_path == "b.txt")
  for _, e in ipairs(events) do
    assert(
      not (e.data.view_id == changed.id and e.name == "DiffreelFileSelect" and e.data.path == "a.txt"),
      "Stale selection hook continued"
    )
  end
  vim.api.nvim_del_autocmd(selector)
  plugin.close(changed)
end, debug.traceback)
vim.api.nvim_del_augroup_by_id(group)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
