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
local rows = {}
for i = 1, 120 do
  rows[i] = "line " .. i .. " same"
end
for _, name in ipairs({ "a", "b" }) do
  vim.fn.writefile(rows, root .. "/" .. name)
end
git({ "add", "." })
git({ "commit", "-qm", "base" })
for _, row in ipairs({ 5, 40, 95 }) do
  rows[row] = "line " .. row .. " changed"
end
for _, name in ipairs({ "a", "b" }) do
  vim.fn.writefile(rows, root .. "/" .. name)
end
local failures, passed = {}, 0
local function ready(view)
  assert(vim.wait(10000, function()
    return view.error or (view.ready and not view.updating and not view.inline_pending and not view.layout_pending)
  end, 5))
  assert(not view.error, view.error)
end
local function open(opts)
  opts = vim.tbl_extend("force", { root = root }, opts or {})
  local view = plugin.open(opts)
  ready(view)
  return view
end
local function test(name, run)
  local selected = vim.env.DIFFREEL_EXPLORATION_CASE
  if selected and selected ~= name then
    return
  end
  plugin.setup({ watch = false, keymaps = {} })
  local ok, err = xpcall(run, debug.traceback)
  plugin.shutdown()
  vim.cmd("silent! tabonly!")
  for _, info in ipairs(vim.fn.getbufinfo()) do
    if info.name:sub(1, #root + 1) == root .. "/" then
      vim.api.nvim_buf_delete(info.bufnr, { force = true })
    end
  end
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end

test("split-bindings", function()
  local view = open()
  for _, mode in ipairs({ "stacked", "side_by_side", "inline", "stacked", "side_by_side" }) do
    plugin.set_layout(view, mode)
    ready(view)
    if mode ~= "inline" then
      for _, win in ipairs({ view.left_win, view.right_win }) do
        assert(vim.wo[win].scrollbind and vim.wo[win].cursorbind, mode .. " lost native diff binding")
      end
    end
  end
end)

test("ordinary-foldenable", function()
  vim.wo.foldenable, vim.wo.foldmethod = true, "manual"
  local view = open()
  local buf = view.right_buf
  plugin.close(view)
  vim.api.nvim_set_current_buf(buf)
  assert(vim.wo.foldenable, "Review disabled folding in the ordinary file window")
end)

test("explicit-hunk-mapping", function()
  local calls = 0
  vim.keymap.set("n", "]c", function()
    calls = calls + 1
  end)
  plugin.setup({ keymaps = { defaults = false, diff = { ["]c"] = "next_change" } } })
  local view = open()
  vim.api.nvim_set_current_win(view.right_win)
  vim.api.nvim_win_set_cursor(view.right_win, { 1, 0 })
  vim.api.nvim_feedkeys("]c", "xt", false)
  vim.keymap.del("n", "]c")
  assert(
    calls == 0 and vim.api.nvim_win_get_cursor(view.right_win)[1] == 5,
    "Explicit action fell back to a global mapping"
  )
end)

test("inline-diffanchors", function()
  local view = open()
  vim.bo[view.right_buf].diffanchors = "1"
  local ok = pcall(plugin.set_layout, view, "inline")
  assert(not ok and view.layout == "side_by_side", "Inline accepted unsupported buffer-local diffanchors")
  vim.bo[view.right_buf].diffanchors = ""
  vim.go.diffanchors = "1"
  ok = pcall(plugin.set_layout, view, "inline")
  vim.go.diffanchors = ""
  assert(not ok and view.layout == "side_by_side", "Inline ignored global diffanchors")
  plugin.set_layout(view, "inline")
  ready(view)
  vim.bo[view.right_buf].diffanchors = "1"
  vim.api.nvim_exec_autocmds("OptionSet", { pattern = "diffanchors" })
  assert(
    vim.wait(5000, function()
      return view.layout == "side_by_side"
    end, 5),
    "Inline did not fall back after an anchor change"
  )
end)

test("initial-split-failure", function()
  local width, minimum = vim.o.winwidth, vim.o.winminwidth
  vim.cmd.edit(root .. "/a")
  local source, tab, count =
    vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_tabpage(), #vim.api.nvim_list_bufs()
  vim.api.nvim_buf_set_lines(source, 0, 1, false, { "draft" })
  vim.o.winwidth = vim.o.columns
  vim.o.winminwidth = vim.o.columns
  local ok = pcall(plugin.open, { root = root, explorer = { visible = false } })
  vim.o.winminwidth = minimum
  vim.o.winwidth = width
  assert(not ok, "Fixture did not prevent split allocation")
  assert(
    vim.api.nvim_get_current_tabpage() == tab and #vim.api.nvim_list_tabpages() == 1,
    "Failed open left an orphan tab"
  )
  assert(#vim.api.nvim_list_bufs() == count, "Failed open leaked owned buffers")
  assert(vim.api.nvim_get_current_buf() == source and vim.bo[source].modified)
end)

test("initial-tab-callback-failure", function()
  local tabs, buffers = vim.api.nvim_list_tabpages(), vim.api.nvim_list_bufs()
  vim.api.nvim_create_autocmd("TabNewEntered", {
    once = true,
    callback = function()
      error("Tab setup fixture")
    end,
  })
  local ok = pcall(plugin.open, { root = root })
  assert(not ok, "Fixture did not reject tab creation")
  assert(vim.deep_equal(vim.api.nvim_list_tabpages(), tabs), "Failed tab callback left an orphan tab")
  assert(vim.deep_equal(vim.api.nvim_list_bufs(), buffers), "Failed tab callback leaked a scratch buffer")
end)

test("file-from-help", function()
  local view = open()
  vim.api.nvim_set_current_win(view.explorer_win)
  plugin.show_help(view)
  local other = plugin.open({ file = true })
  ready(other)
  assert(other.root == view.root and other.pinned_path == view.selected_path, "Help lost its review context")
end)

test("completion-review-root", function()
  git({ "branch", "review-only" })
  local view = open()
  vim.api.nvim_set_current_win(view.explorer_win)
  assert(
    vim.tbl_contains(vim.fn.getcompletion("Diffreel --file=a", "cmdline"), "--file=a"),
    "Path completion used another repository"
  )
  assert(
    vim.wait(5000, function()
      return vim.tbl_contains(vim.fn.getcompletion("Diffreel review-", "cmdline"), "review-only")
    end, 5),
    "Ref completion used another repository"
  )
end)

vim.fn.delete(root, "rf")
for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
