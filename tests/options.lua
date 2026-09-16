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

test("status icons inherit individual keys without sharing input tables", function()
  local options = require("diffreel.options")
  local config = { explorer = { status_icons = { added = "+", modified = "~" } } }
  local input = { explorer = { status_icons = { modified = "変更" } } }
  local resolved = options.normalize(input, config).explorer
  eq("+", resolved.status_icons.added)
  eq("変更", resolved.status_icons.modified)
  eq("", resolved.status_icons.deleted)
  local updated = options.explorer({ status_icons = { renamed = ">" } }, resolved)
  eq("変更", updated.status_icons.modified)
  eq(">", updated.status_icons.renamed)
  updated.status_icons.modified = "M"
  eq("変更", resolved.status_icons.modified)
  eq("変更", input.explorer.status_icons.modified)
  eq("~", config.explorer.status_icons.modified)
  local plugin = require("diffreel")
  plugin.setup(config)
  plugin.setup(input)
  eq("+", plugin.config.explorer.status_icons.added)
  eq("変更", plugin.config.explorer.status_icons.modified)
end)

test("invalid status icons leave configured settings intact", function()
  local options, plugin = require("diffreel.options"), require("diffreel")
  local before = vim.deepcopy(plugin.config)
  for _, icons in ipairs({ false, "M", { unknown_key = "?" }, { modified = false }, { modified = "" } }) do
    local input = { explorer = { status_icons = icons } }
    assert(not pcall(options.normalize, input, {}), vim.inspect(icons))
    assert(not pcall(plugin.setup, input), vim.inspect(icons))
    eq(before, plugin.config)
  end
  for _, char in ipairs({ "\0", "\n", "\r", "\t", "\27", "\127", "\194\133" }) do
    local input = { explorer = { status_icons = { modified = "a" .. char .. "b" } } }
    assert(not pcall(options.normalize, input, {}), vim.inspect(char))
    assert(not pcall(plugin.setup, input), vim.inspect(char))
    eq(before, plugin.config)
  end
end)

test("spinner settings inherit individual keys without sharing input tables", function()
  local options, spinner = require("diffreel.options"), require("diffreel.spinner")
  eq(spinner.defaults, options.spinner(nil, nil))
  local defaults = options.spinner(nil, nil)
  defaults.frames[1] = "x"
  eq("⠋", spinner.defaults.frames[1])
  local input = { frames = { "-", "|" } }
  local resolved = options.spinner(input, nil)
  eq({ "-", "|" }, resolved.frames)
  eq(80, resolved.interval)
  resolved.frames[1] = "+"
  eq("-", input.frames[1])
  local updated = options.spinner({ interval = 120 }, resolved)
  eq({ "+", "|" }, updated.frames)
  eq(120, updated.interval)
  eq(false, options.spinner(false, nil))
  eq(false, options.spinner(nil, false))
  eq(spinner.defaults.frames, options.spinner({ interval = 200 }, false).frames)
  eq(200, options.spinner({ interval = 200 }, false).interval)
end)

test("invalid spinner settings are rejected and leave configuration intact", function()
  local options, plugin = require("diffreel.options"), require("diffreel")
  local before = vim.deepcopy(plugin.config)
  for _, value in ipairs({
    "braille",
    0,
    { frames = {} },
    { frames = "⠋" },
    { frames = { "⠋", "あ" } },
    { frames = { "⠋", "" } },
    { frames = { "⠋", "a\tb" } },
    { frames = { "⠋", "a\194\133b" } },
    { interval = 15 },
    { interval = 80.5 },
    { interval = "80" },
    { unknown_key = 1 },
  }) do
    assert(not pcall(options.spinner, value, nil), vim.inspect(value))
    assert(not pcall(plugin.setup, { spinner = value }), vim.inspect(value))
    eq(before, plugin.config)
  end
end)

test("spinner is a setup option that open() does not carry", function()
  local options, plugin = require("diffreel.options"), require("diffreel")
  assert(not pcall(options.normalize, { spinner = false }, {}), "normalize accepted a per-open spinner")
  assert(not pcall(options.normalize, { spinner = { interval = 100 } }, {}), "normalize accepted a per-open spinner")
  plugin.setup({ spinner = { interval = 160 } })
  eq(160, plugin.config.spinner.interval)
  eq(require("diffreel.spinner").defaults.frames, plugin.config.spinner.frames)
  plugin.setup({})
  eq(160, plugin.config.spinner.interval)
  plugin.setup({ spinner = false })
  eq(false, plugin.config.spinner)
  plugin.setup({})
  eq(false, plugin.config.spinner)
  plugin.setup({ spinner = { interval = 80 } })
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
