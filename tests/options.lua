vim.opt.rtp:prepend(vim.fn.getcwd())
local failures, passed = {}, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

test("staged and unstaged commands select read-only index endpoints", function()
  local options = require("diffreel.options")
  eq({ left = "HEAD", right = ":0" }, options.parse({ "--staged" }))
  eq({ left = "HEAD~1", right = ":0" }, options.parse({ "--cached", "HEAD~1" }))
  eq({ left = ":0", right = "worktree" }, options.parse({ "--unstaged" }))
  eq({}, options.parse({}))
  eq({ help = true }, options.parse({ "--help" }))
end)

test("comparison options preserve escaped paths and exclusion meaning", function()
  local options = require("diffreel.options")
  local opts = options.parse({
    "-C",
    "/a repo",
    "--exclude=**/*.lock",
    "--exclude",
    "dist/**",
    "--untracked=no",
    "--stat",
    "--selected-file=a file.lua",
    "HEAD~1",
    "--",
    "src",
    ":(literal)a file.lua",
  })
  eq("/a repo", opts.root)
  eq("a file.lua", opts.selected_file)
  eq(false, opts.untracked)
  eq(true, opts.line_stats)
  local resolved = options.normalize(opts, {})
  eq({ "src", ":(literal)a file.lua", ":(exclude,glob)**/*.lock", ":(exclude,glob)dist/**" }, resolved.paths)
  eq("HEAD~1", resolved.left)
  eq("worktree", resolved.right)
end)

test("view overrides replace configured scopes without sharing mutable arrays", function()
  local options = require("diffreel.options")
  local config =
    { paths = { "src" }, exclude = { "**/*.lock" }, untracked = false, line_stats = true, selected_file = false }
  local a = options.normalize({}, config)
  local b = options.normalize({ paths = {}, exclude = {}, untracked = true, line_stats = false }, config)
  eq({ "src", ":(exclude,glob)**/*.lock" }, a.paths)
  eq({}, b.paths)
  eq(false, a.selected_file)
  eq(true, b.untracked)
  eq(false, b.line_stats)
  a.paths[1] = "changed"
  eq({ "src" }, config.paths)
end)

test("triple-dot comparisons resolve without splitting revision selectors", function()
  local options = require("diffreel.options")
  local a = options.normalize(options.parse({ "main...feature" }), {})
  eq("main", a.left)
  eq("feature", a.right)
  eq(true, a.merge_base)
  local b = options.normalize({ left = "main..." }, {})
  eq("worktree", b.right)
  eq(true, b.merge_base)
  local c = options.normalize({ left = "HEAD^{/fix...bug}" }, {})
  eq("HEAD^{/fix...bug}", c.left)
  eq(false, c.merge_base)
end)

test("invalid command and API combinations are rejected before opening windows", function()
  local options = require("diffreel.options")
  for _, args in ipairs({
    { "--staged", "--unstaged" },
    { "--unstaged", "HEAD" },
    { "--staged", "HEAD", "HEAD~1" },
    { "--unknown" },
    { "--exclude" },
    { "--untracked=normal" },
    { "a", "b", "c" },
  }) do
    assert(not pcall(options.parse, args), vim.inspect(args))
  end
  for _, opts in ipairs({
    { paths = "src" },
    { paths = { false } },
    { paths = { [2] = "src" } },
    { paths = { "a\0b" } },
    { exclude = { "" } },
    { untracked = "no" },
    { selected_file = true },
    { line_stats = 1 },
    { left = "main...feature", right = "HEAD" },
    { left = ":0", merge_base = true },
    { left = false },
  }) do
    assert(not pcall(options.normalize, opts, {}), vim.inspect(opts))
  end
end)

test("initial file preferences remain literal repository-relative paths", function()
  local options = require("diffreel.options")
  eq("src/a.lua", options.preferred_path("/repo", "/repo/src/a.lua", nil))
  eq("src/a.lua", options.preferred_path("/repo", "/elsewhere/a", "src/./a.lua"))
  eq("a file.lua", options.preferred_path("/repo", "", "/repo/a file.lua"))
  eq(nil, options.preferred_path("/repo", "/repository/a", nil))
  eq(nil, options.preferred_path("/repo", "/repo/a", false))
  eq(nil, options.preferred_path("/repo", "", "../outside"))
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
