vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = assert(vim.uv.fs_realpath(root))
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
for _, path in ipairs({ "a", "b" }) do
  vim.fn.writefile({ "old " .. path, "same", "tail" }, root .. "/" .. path)
end
git({ "add", "." })
git({ "commit", "-qm", "base" })
for _, path in ipairs({ "a", "b" }) do
  vim.fn.writefile({ "new " .. path, "same", "tail" }, root .. "/" .. path)
end
local failures, passed = {}, 0
local function ready(v)
  assert(vim.wait(10000, function()
    return v.error or (v.ready and not v.inline_pending and not v.layout_pending and not v.requested_layout)
  end, 5))
  assert(not v.error, v.error)
end
local function test(name, body)
  local before = vim.o.diffopt
  local ok, err = xpcall(body, debug.traceback)
  vim.o.diffopt = before
  for _, view in pairs(vim.tbl_extend("force", {}, plugin.views)) do
    plugin.close(view)
  end
  plugin.shutdown()
  vim.cmd("silent! tabonly!")
  for _, info in ipairs(vim.fn.getbufinfo()) do
    if info.name:sub(1, #root + 1) == root .. "/" then
      vim.api.nvim_buf_delete(info.bufnr, { force = true })
    end
  end
  plugin.setup({ watch = false })
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
plugin.setup({ watch = false })
for _, column in ipairs({ "0", "3" }) do
  for _, initial in ipairs({ "side_by_side", "inline" }) do
    test("cached ordinary options after " .. initial .. " with foldcolumn=" .. column, function()
      vim.wo.number, vim.wo.wrap, vim.wo.foldmethod, vim.wo.foldexpr = false, true, "manual", "0"
      vim.wo.foldcolumn, vim.wo.scrollbind, vim.wo.cursorbind = column, false, false
      local v = plugin.open({ root = root, layout = initial })
      ready(v)
      plugin.set_layout(v, "inline")
      ready(v)
      local source = v.right_buf
      plugin.close(v)
      vim.api.nvim_set_current_buf(source)
      assert(
        not vim.wo.number
          and vim.wo.wrap
          and vim.wo.foldmethod == "manual"
          and vim.wo.foldexpr == "0"
          and vim.wo.foldcolumn == column
          and not vim.wo.scrollbind
          and not vim.wo.cursorbind,
        vim.inspect(require("diffreel.presentation").capture_window(vim.api.nvim_get_current_win()))
      )
    end)
  end
end
test("partial engine allocation leaves no pending transition", function()
  local v = plugin.open({ root = root })
  ready(v)
  local open, count = vim.api.nvim_open_win, 0
  vim.api.nvim_open_win = function(...)
    count = count + 1
    if count == 2 then
      error("allocation fixture")
    end
    return open(...)
  end
  local ok = pcall(plugin.set_layout, v, "inline")
  vim.api.nvim_open_win = open
  assert(not ok and v.alive and v.layout == "side_by_side" and not v.layout_pending)
  assert(not v.layout_staging and #vim.api.nvim_tabpage_list_wins(v.tab) == 3)
end)
test("failed inline-to-stacked geometry restores a usable inline view", function()
  local v = plugin.open({ root = root, layout = "inline" })
  ready(v)
  local setter = vim.api.nvim_win_set_height
  vim.api.nvim_win_set_height = function()
    error("height fixture")
  end
  local ok = pcall(plugin.set_layout, v, "stacked")
  vim.api.nvim_win_set_height = setter
  ready(v)
  assert(not ok and v.alive and v.layout == "inline" and vim.api.nvim_win_is_valid(v.right_engine))
  assert(vim.api.nvim_win_get_config(v.left_win).hide)
  plugin.select(v, "b")
  ready(v)
  assert(v.selected_path == "b")
end)
test("unsupported inline requests are atomic", function()
  local v = plugin.open({ root = root })
  ready(v)
  local before = vim.fn.winlayout()
  vim.opt.diffopt:append("icase")
  assert(not pcall(plugin.set_layout, v, "inline"))
  assert(v.layout == "side_by_side" and vim.deep_equal(vim.fn.winlayout(), before))
  local tabs, buffers = #vim.api.nvim_list_tabpages(), #vim.api.nvim_list_bufs()
  assert(not pcall(plugin.open, { root = root, layout = "inline" }))
  assert(#vim.api.nvim_list_tabpages() == tabs and #vim.api.nvim_list_bufs() == buffers)
end)
test("API capability failure does not create a view", function()
  local set = vim.api.nvim__ns_set
  vim.api.nvim__ns_set = function()
    error("capability fixture")
  end
  local tabs = #vim.api.nvim_list_tabpages()
  local ok = pcall(plugin.open, { root = root, layout = "inline" })
  vim.api.nvim__ns_set = set
  assert(not ok and #vim.api.nvim_list_tabpages() == tabs)
end)
test("option and size limits return to a split with drafts intact", function()
  local v = plugin.open({ root = root, layout = "inline" })
  ready(v)
  local buf = v.right_buf
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "draft" })
  ready(v)
  vim.opt.diffopt:append("icase")
  vim.api.nvim_exec_autocmds("OptionSet", { pattern = "diffopt" })
  assert(vim.wait(10000, function()
    return v.layout == "side_by_side"
  end, 5))
  assert(vim.bo[buf].modified and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "draft")
  vim.opt.diffopt:remove("icase")
  plugin.set_layout(v, "inline")
  ready(v)
  local rows = {}
  for i = 1, 20001 do
    rows[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
  assert(vim.wait(10000, function()
    return v.layout == "side_by_side"
  end, 5))
  assert(vim.bo[buf].modified and vim.api.nvim_buf_line_count(buf) == 20001)
end)
test("byte cap clears inline without truncating a draft", function()
  local v = plugin.open({ root = root, layout = "inline" })
  ready(v)
  local buf = v.right_buf
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { string.rep("x", 1048576) })
  assert(vim.wait(10000, function()
    return v.layout == "side_by_side"
  end, 5))
  assert(vim.bo[buf].modified and #vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 1048576)
  assert(not v.inline_namespace or #vim.api.nvim_buf_get_extmarks(buf, v.inline_namespace, 0, -1, {}) == 0)
end)
test("two inline views scope a shared buffer independently", function()
  local first = plugin.open({ root = root, layout = "inline" })
  ready(first)
  local second = plugin.open({ root = root, left = "", layout = "inline" })
  ready(second)
  assert(first.right_buf == second.right_buf)
  assert(first.inline_namespace ~= second.inline_namespace)
  assert(vim.deep_equal(vim.api.nvim__ns_get(first.inline_namespace).wins, { first.right_win }))
  assert(vim.deep_equal(vim.api.nvim__ns_get(second.inline_namespace).wins, { second.right_win }))
  local current = vim.api.nvim_get_current_tabpage()
  plugin.set_layout(first, "stacked")
  ready(first)
  assert(vim.api.nvim_get_current_tabpage() == current and second.alive and second.layout == "inline")
  plugin.close(first)
  assert(second.alive and vim.api.nvim_buf_is_valid(second.right_buf))
end)
test("selection completion survives accepted layout changes", function()
  local v = plugin.open({ root = root })
  ready(v)
  local backend, pending = v.manager.backend, {}
  local request = backend.request
  backend.request = function(self, method, params, done)
    request(self, method, params, function(err, value)
      if method == "blob/read" then
        pending[#pending + 1] = function()
          done(err, value)
        end
      else
        done(err, value)
      end
    end)
  end
  plugin.select(v, "b")
  assert(vim.wait(5000, function()
    return #pending > 0
  end, 5))
  plugin.set_layout(v, "inline")
  backend.request = request
  for _, deliver in ipairs(pending) do
    deliver()
  end
  ready(v)
  assert(v.layout == "inline" and v.selected_path == "b")
end)
test("native mappings fall back in split and ordinary windows", function()
  local calls = 0
  vim.keymap.set("n", "]c", function()
    calls = calls + 1
  end)
  local v = plugin.open({ root = root })
  ready(v)
  vim.api.nvim_set_current_win(v.right_win)
  vim.api.nvim_feedkeys("]c", "xt", false)
  assert(calls == 1)
  plugin.set_layout(v, "inline")
  ready(v)
  vim.api.nvim_feedkeys("]c", "xt", false)
  assert(calls == 1)
  plugin.set_layout(v, "stacked")
  vim.api.nvim_feedkeys("]c", "xt", false)
  assert(calls == 2)
  vim.keymap.del("n", "]c")
end)
test("definition navigation defers inline until the source returns", function()
  local v = plugin.open({ root = root })
  ready(v)
  local source = v.right_buf
  local target = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(target, 0, -1, false, { "definition draft" })
  vim.api.nvim_win_set_buf(v.right_win, target)
  assert(vim.wait(5000, function()
    return v.navigation
  end, 5))
  plugin.set_layout(v, "inline")
  assert(v.requested_layout == "inline" and vim.api.nvim_win_get_buf(v.right_win) == target)
  vim.api.nvim_win_set_buf(v.right_win, source)
  ready(v)
  assert(v.layout == "inline" and vim.bo[target].modified)
end)
test("empty and missing endpoints never render placeholder lines as changes", function()
  local cases = {
    { file = "missing", removed = false, added = false },
    { file = "empty", removed = false, added = false },
    { file = "a", left = "", removed = false, added = true },
    { file = "a", deleted = true, removed = true, added = false },
    { file = "a", metadata = true, removed = false, added = false },
  }
  vim.fn.writefile({}, root .. "/empty")
  for _, case in ipairs(cases) do
    if case.deleted then
      vim.fn.delete(root .. "/a")
    elseif case.metadata then
      vim.fn.writefile({ "old a", "same", "tail" }, root .. "/a", "b")
    end
    local v = plugin.open({ root = root, file = case.file, left = case.left, layout = "inline" })
    ready(v)
    assert(v.layout == "inline", vim.inspect(case))
    assert((#v.inline_cache.deletions > 0) == case.removed, vim.inspect(case))
    assert((next(v.inline_cache.right) ~= nil) == case.added, vim.inspect(case))
    plugin.close(v)
    plugin.shutdown()
  end
end)
plugin.shutdown()
vim.fn.delete(root, "rf")
for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
