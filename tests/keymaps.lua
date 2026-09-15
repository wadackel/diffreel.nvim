vim.opt.rtp:prepend(vim.fn.getcwd())
local keys = require("diffreel.keymaps")
local plugin = require("diffreel")
local failures, passed = {}, 0
local function test(name, body)
  local ok, err = xpcall(body, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
local function by_lhs(maps)
  local result = {}
  for _, binding in ipairs(maps) do
    result[binding.lhs] = binding.action
  end
  return result
end

test("defaults, overlays, aliases and complete opt-out", function()
  vim.g.mapleader = ","
  local defaults = keys.resolve()
  assert(#defaults.explorer == 24 and #defaults.diff == 13)
  assert(#defaults.diff_visual == 1 and #defaults.diff_operator == 1)
  assert(defaults.diff_visual[1].action == "select_hunk" and defaults.diff_visual[1].mode == "x")
  assert(by_lhs(defaults.explorer)["<Tab>"] == "next_file")
  assert(by_lhs(defaults.diff)[",e"] == "focus_explorer")
  local callback = function() end
  local input = { explorer = { q = false, ["<Esc>"] = "close", ["]f"] = "next_file" }, diff = { X = callback } }
  local result = keys.resolve(input)
  assert(not by_lhs(result.explorer).q and by_lhs(result.diff).q == "close")
  assert(by_lhs(result.explorer)["<Esc>"] == "close" and by_lhs(result.explorer)["]f"] == "next_file")
  assert(by_lhs(result.diff).X == callback and input.explorer.q == false)
  local empty = keys.resolve({ defaults = false })
  assert(#empty.explorer == 0 and #empty.diff == 0)
  local custom = keys.resolve({ defaults = false, explorer = { x = callback } })
  assert(#custom.explorer == 1 and #custom.diff == 0)
end)

test("tree and clipboard defaults remain configurable and explorer-only", function()
  local names = {
    ["<C-H>"] = "collapse_node",
    ["^"] = "parent",
    E = "expand_recursive",
    W = "collapse_recursive",
    gE = "expand_all",
    gW = "collapse_all",
    yp = "yank_path",
    yP = "yank_path_absolute",
    yn = "yank_name",
  }
  local defaults = by_lhs(keys.resolve().explorer)
  for lhs, action in pairs(names) do
    assert(defaults[lhs] == action)
    assert(not pcall(keys.resolve, { diff = { X = action } }))
    local policy = keys.resolve({ explorer = { [lhs] = false, X = action } })
    assert(not by_lhs(policy.explorer)[lhs] and by_lhs(policy.explorer).X == action)
  end
end)

test("native modifier identity and literal key notation survive resolution", function()
  vim.g.mapleader, vim.g.maplocalleader = "<Space>", ";"
  local policy = keys.resolve({
    defaults = false,
    diff = {
      ["<Tab>"] = "next_file",
      ["<C-i>"] = "prev_file",
      ["<lt>CR>"] = "close",
      ["<Leader>x"] = "refresh",
      ["<LocalLeader>y"] = "refresh",
    },
  })
  local maps = by_lhs(policy.diff)
  assert(maps["<Tab>"] == "next_file" and maps["<C-I>"] == "prev_file")
  assert(maps["<lt>CR>"] == "close" and maps["<lt>Space>x"] == "refresh" and maps[";y"] == "refresh")
  local buf = vim.api.nvim_create_buf(false, true)
  for _, binding in ipairs(policy.diff) do
    vim.keymap.set("n", binding.lhs, function() end, { buffer = buf })
  end
  local actual = {}
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
    actual[mapping.lhsraw] = true
  end
  for _, binding in ipairs(policy.diff) do
    assert(actual[binding.raw], binding.lhs)
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.g.mapleader, vim.g.maplocalleader = ",", "\\"
end)

test("invalid configuration is rejected before setup mutation", function()
  plugin.setup({ daemon = vim.env.DIFFREEL_DAEMON, watch = false })
  local config = plugin.config
  local before = #vim.api.nvim_list_bufs()
  for _, input in ipairs({
    false,
    { defaults = "no" },
    { panes = {} },
    { explorer = false },
    { diff = { [""] = "close" } },
    { diff = { [1] = "close" } },
    { diff = { x = true } },
    { diff = { x = {} } },
    { diff = { x = "unknown" } },
    { diff = { x = "select_entry" } },
    { diff = { x = "edit_file" } },
    { diff = { x = "select_hunk" } },
    { diff_operator = { x = "close" } },
    { diff = { [string.rep("x", 60)] = "close" } },
    { diff = { ["<S-a>"] = "close", A = "refresh" } },
    { diff = { ["<Plug>(DiffreelAction-1-1)"] = "close" } },
    { explorer = { ["<Plug>(DiffreelFallback-1-1)"] = false } },
  }) do
    local ok = pcall(plugin.setup, { width = 44, keymaps = input })
    assert(not ok, vim.inspect(input))
    assert(plugin.config == config and plugin.config.width ~= 44)
    assert(#vim.api.nvim_list_bufs() == before, "Validation retained a scratch buffer")
  end
  local ok = pcall(plugin.setup, { backend = "invalid", keymaps = {} })
  assert(not ok and plugin.config == config)
end)

test("setup copies inputs, preserves omissions and resets supplied policies", function()
  local input = { defaults = false, diff = { ["<Leader>x"] = "close" } }
  plugin.setup({ keymaps = input })
  input.diff["<Leader>x"] = "refresh"
  assert(plugin.config.keymaps.diff["<Leader>x"] == "close")
  local saved = vim.deepcopy(plugin.config.keymaps)
  plugin.setup({ width = 32 })
  assert(vim.deep_equal(plugin.config.keymaps, saved))
  plugin.setup({ keymaps = {} })
  assert(vim.deep_equal(plugin.config.keymaps, {}))
end)

test("buffer autocmd mappings do not change normalized key identities", function()
  local event = vim.api.nvim_create_autocmd("BufNew", {
    callback = function(args)
      vim.keymap.set("n", "a", "gg", { buffer = args.buf })
    end,
  })
  local ok, policy = pcall(keys.resolve, { defaults = false, diff = { x = "close", y = "refresh" } })
  vim.api.nvim_del_autocmd(event)
  assert(ok, policy)
  local mappings = by_lhs(policy.diff)
  assert(mappings.x == "close" and mappings.y == "refresh" and not mappings.a)
end)

test("invalid view and daemon options leave configuration and editor intact", function()
  local config = plugin.config
  local tabs, buffers = #vim.api.nvim_list_tabpages(), #vim.api.nvim_list_bufs()
  for _, opts in ipairs({
    { width = -1 },
    { width = 0 },
    { width = 1.5 },
    { width = "30" },
    { width = math.huge },
    { max_bytes = 0 },
    { max_bytes = false },
    { reconcile_ms = -1 },
    { watch = "false" },
    { auto_install = 1 },
    { daemon = {} },
    { daemon = "" },
  }) do
    assert(not pcall(plugin.setup, opts), "Accepted invalid options: " .. vim.inspect(opts))
    assert(plugin.config == config)
    assert(#vim.api.nvim_list_tabpages() == tabs and #vim.api.nvim_list_bufs() == buffers)
  end
end)

for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
