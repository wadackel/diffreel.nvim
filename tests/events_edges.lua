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
  local r = vim.system(cmd, { cwd = root, text = true }):wait()
  assert(r.code == 0, r.stderr)
end
git({ "init", "-qb", "main" })
vim.fn.writefile({ "old", "same" }, root .. "/a")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile({ "new", "same" }, root .. "/a")
local failures, passed = {}, 0
local function ready(v)
  assert(vim.wait(5000, function()
    return v.ready or not v.alive or v.error
  end, 5))
  assert(not v.error, v.error)
end
local function test(name, body)
  plugin.setup({ watch = false })
  local group = vim.api.nvim_create_augroup("event_edge", { clear = true })
  local ok, err = xpcall(function()
    body(group)
  end, debug.traceback)
  vim.api.nvim_del_augroup_by_id(group)
  for _, v in pairs(vim.tbl_extend("force", {}, plugin.views)) do
    pcall(plugin.close, v)
  end
  plugin.shutdown()
  vim.cmd("silent! tabonly!")
  vim.wait(10, function()
    return false
  end)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
for _, name in ipairs({ "Open", "Enter", "DiffBufRead", "FileSelect", "Ready", "LayoutChanged", "Leave", "Close" }) do
  test("exception in " .. name, function(group)
    local called = false
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "Diffreel" .. name,
      once = true,
      callback = function()
        called = true
        error("injected " .. name .. " hook error")
      end,
    })
    local v = plugin.open({ root = root })
    ready(v)
    plugin.set_explorer(v, { visible = false })
    plugin.close(v)
    assert(called and not v.alive and not plugin.get_view(v.id))
  end)
end
for _, name in ipairs({ "Open", "Enter", "DiffBufRead", "FileSelect", "Ready", "LayoutChanged", "Leave" }) do
  test("close inside " .. name, function(group)
    local home = vim.api.nvim_get_current_tabpage()
    local closed
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "Diffreel" .. name,
      once = true,
      callback = function(e)
        closed = plugin.get_view(e.data.view_id)
        plugin.close(closed)
      end,
    })
    local v = plugin.open({ root = root })
    ready(v)
    if v.alive then
      plugin.set_explorer(v, { visible = false })
    end
    if v.alive then
      vim.api.nvim_set_current_tabpage(home)
    end
    assert(vim.wait(1000, function()
      return not v.alive
    end, 5))
    assert(closed == v and not plugin.get_view(v.id))
  end)
end
test("shutdown cannot be repopulated by a Close hook", function(group)
  local v = plugin.open({ root = root })
  ready(v)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffreelClose",
    once = true,
    callback = function()
      plugin.open({ root = root })
    end,
  })
  plugin.shutdown()
  assert(next(plugin.views) == nil and next(plugin.managers) == nil)
end)
test("Close can open a replacement review", function(group)
  local replacement
  local v = plugin.open({ root = root })
  ready(v)
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffreelClose",
    once = true,
    callback = function()
      replacement = plugin.open({ root = root })
    end,
  })
  plugin.close(v)
  assert(replacement and replacement.alive)
  ready(replacement)
end)
for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
vim.fn.delete(root, "rf")
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
