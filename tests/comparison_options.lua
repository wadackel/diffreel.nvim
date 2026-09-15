vim.opt.rtp:prepend(vim.fn.getcwd())
local diffreel = require("diffreel")
local root = vim.fn.tempname() .. " repo"
vim.fn.mkdir(root .. "/src", "p")
local failures, passed = {}, 0
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
  return vim.trim(result.stdout)
end
local function write(path, value)
  local file = assert(io.open(root .. "/" .. path, "wb"))
  file:write(value)
  file:close()
end
local function wait(view)
  assert(
    vim.wait(10000, function()
      return view.ready or view.error
    end, 5),
    "Comparison timed out"
  )
  assert(not view.error, view.error)
  return view
end
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
  for _, view in pairs(vim.tbl_extend("force", {}, diffreel.views)) do
    diffreel.close(view)
  end
end

git({ "init", "-q", "-b", "main" })
for _, path in ipairs({ "src/a.lua", "src/b.lua", "other.txt" }) do
  write(path, "base\n")
end
git({ "add", "." })
git({ "commit", "-qm", "base" })
local base = git({ "rev-parse", "HEAD" })
write("src/a.lua", "staged\n")
git({ "add", "src/a.lua" })
write("src/a.lua", "working\n")
write("src/b.lua", "changed b\n")
write("other.txt", "changed other\n")
write("src/new.lua", "untracked\n")
diffreel.setup({ watch = false })

test("the invoking real file is selected only on the initial snapshot", function()
  vim.cmd.edit(vim.fn.fnameescape(root .. "/src/b.lua"))
  local view = wait(diffreel.open({ root = root }))
  assert(view.selected_path == "src/b.lua", "Invoking file was not selected")
  diffreel.select(view, "src/a.lua")
  wait(view)
  diffreel.refresh(view)
  assert(vim.wait(5000, function()
    return not view.updating
  end, 5))
  assert(view.selected_path == "src/a.lua", "Refresh reset initial selection")
end)

test("scoped views have independent membership and explicit initial selection", function()
  local scoped = wait(diffreel.open({
    root = root,
    paths = { "src" },
    exclude = { "**/a.lua" },
    untracked = false,
    selected_file = "src/b.lua",
  }))
  assert(#scoped.entries == 1 and scoped.selected_path == "src/b.lua")
  local all = wait(diffreel.open({ root = root, selected_file = false }))
  assert(#all.entries == 4 and all.selected_path == all.entries[1].path and all.selected_path ~= "src/b.lua")
  assert(all.comparison.comparison_id ~= scoped.comparison.comparison_id)
end)

test("the command opens distinct staged and unstaged endpoints", function()
  vim.api.nvim_cmd({ cmd = "Diffreel", args = { "--repo", root, "--staged", "--", "src" } }, {})
  local staged = wait(diffreel.get_current())
  assert(staged.comparison.right == ":0" and #staged.entries == 1)
  assert(vim.bo[staged.right_buf].buftype == "nofile" and not vim.bo[staged.right_buf].modifiable)
  assert(vim.api.nvim_buf_get_lines(staged.right_buf, 0, -1, false)[1] == "staged")
  vim.api.nvim_cmd({
    cmd = "Diffreel",
    args = { "--repo", root, "--unstaged", "--untracked=no", "--selected-file=src/a.lua", "--", "src" },
  }, {})
  local unstaged = wait(diffreel.get_current())
  assert(unstaged.comparison.left == ":0" and #unstaged.entries == 2)
  assert(vim.bo[unstaged.right_buf].buftype == "" and vim.bo[unstaged.right_buf].modifiable)
  assert(vim.api.nvim_buf_get_lines(unstaged.left_buf, 0, -1, false)[1] == "staged")
  assert(vim.api.nvim_buf_get_lines(unstaged.right_buf, 0, -1, false)[1] == "working")
end)

test("staging saved text retains an unstaged draft against the new index snapshot", function()
  local view = wait(diffreel.open({ root = root, left = ":0", selected_file = "src/b.lua" }))
  local draft = view.right_buf
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "unsaved b" })
  git({ "add", "src/b.lua" })
  local generation = view.comparison.generation
  diffreel.refresh(view)
  assert(vim.wait(5000, function()
    return view.ready and not view.updating and view.comparison.generation > generation
  end, 5))
  local entry = view.by_path["src/b.lua"]
  assert(entry and entry.buffer_only and view.selected_path == "src/b.lua")
  assert(entry.left.content_id == vim.fn.sha256("changed b\n") and entry.left.content_id == entry.right.content_id)
  assert(vim.bo[draft].modified and vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "unsaved b")
end)

test("merge-base endpoints and scopes survive a backend restart", function()
  local view = wait(
    diffreel.open({ root = root, left = "main...", paths = { "src" }, untracked = false, selected_file = "src/b.lua" })
  )
  assert(view.comparison.left == base and not view.follow_head)
  local manager = view.manager
  git({ "add", "." })
  git({ "commit", "-qm", "new head" })
  manager.backend:close()
  diffreel.refresh(view)
  assert(
    vim.wait(10000, function()
      return view.manager ~= manager and view.ready and not view.switching and not view.updating
    end, 5),
    view.error
  )
  assert(view.comparison.left == base and #view.entries == 3)
  assert(not view.by_path["other.txt"] and view.selected_path == "src/b.lua")
end)

test("HEAD index views follow commits while hidden empty comparisons stay idle", function()
  diffreel.shutdown()
  diffreel.setup({ watch = true, reconcile_ms = 150 })
  local previous = git({ "rev-parse", "HEAD" })
  write("other.txt", "next staged\n")
  git({ "add", "other.txt" })
  local following = wait(diffreel.open({ root = root, right = ":0" }))
  local fixed = wait(diffreel.open({ root = root, left = previous, right = ":0" }))
  assert(following.follow_head and not fixed.follow_head)
  git({ "commit", "-qm", "next staged" })
  local next_head = git({ "rev-parse", "HEAD" })
  assert(
    vim.wait(10000, function()
      return following.ready and not following.updating and following.comparison.left == next_head
    end, 5),
    following.error
  )
  assert(#following.entries == 0 and fixed.comparison.left == previous)
  -- Client readiness can precede the backend's queued visibility update and its last notification.
  local synchronized
  following.manager.backend:request("debug/metrics", {}, function(err)
    assert(not err, err)
    synchronized = true
  end)
  assert(vim.wait(5000, function()
    return synchronized
  end, 5))
  local hidden_generation, visible_generation = following.comparison.generation, fixed.comparison.generation
  assert(vim.wait(5000, function()
    return fixed.comparison.generation >= visible_generation + 2
  end, 5))
  assert(following.comparison.generation == hidden_generation, "Hidden empty index view kept reconciling")
end)

test("invalid options leave configuration and tabs intact", function()
  local tabs = #vim.api.nvim_list_tabpages()
  local config = vim.deepcopy(diffreel.config)
  assert(not pcall(diffreel.open, { root = root, paths = false }))
  assert(not pcall(diffreel.setup, { exclude = "bad" }))
  assert(vim.deep_equal(config, diffreel.config))
  assert(#vim.api.nvim_list_tabpages() == tabs)
end)

diffreel.shutdown()
vim.fn.delete(root, "rf")
for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
