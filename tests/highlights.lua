vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local function hl(name, resolved)
  return vim.api.nvim_get_hl(0, { name = "Diffreel" .. name, link = not resolved, create = false })
end
local ok, err = xpcall(function()
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x123456 })
  vim.api.nvim_set_hl(0, "DiffreelExplorerDirectoryName", { fg = 0xabcdef })
  local calls = 0
  local callback = function(groups)
    calls = calls + 1
    groups.DiffreelExplorerAddedName = { fg = 0x112233 }
    groups.DiffreelExplorerDirectoryName.bold = true
    groups.DiffreelExplorerFileIcon = {}
  end
  plugin.setup({ on_highlight = callback, watch = false })
  assert(calls == 1, "setup did not call on_highlight")
  assert(hl("ExplorerAddedName").fg == 0x112233)
  assert(hl("ExplorerDirectoryName").fg == 0xabcdef and hl("ExplorerDirectoryName").bold)
  assert(vim.deep_equal(hl("ExplorerFileIcon"), {}))
  assert(hl("LineAdd").bg == 0x123456)
  local highlights = require("diffreel.highlights")
  assert(highlights.icon("DiffreelExplorerAddedIcon", "DevIconTest") == "DiffreelExplorerAddedIcon")
  plugin.setup()
  assert(calls == 2)
  plugin.setup({ on_highlight = false })
  assert(hl("ExplorerDirectoryName").fg == 0xabcdef and not hl("ExplorerDirectoryName").bold)
  assert(hl("ExplorerAddedName").link == "DiffreelExplorerFileName")
  assert(highlights.icon("DiffreelExplorerAddedIcon", "DevIconTest") == "DevIconTest")
  vim.api.nvim_set_hl(0, "DiffreelExplorerAddedName", { italic = true })
  plugin.setup()
  assert(hl("ExplorerAddedName").italic, "setup overwrote an external definition")
  plugin.setup({
    on_highlight = function(groups)
      groups.DiffreelExplorerAddedName = {}
    end,
  })
  assert(vim.deep_equal(hl("ExplorerAddedName"), {}))
  plugin.setup({ on_highlight = false })
  assert(hl("ExplorerAddedName").italic, "reset lost the displaced external definition")
  vim.api.nvim_set_hl(0, "DiffreelExplorerFileIcon", { fg = 0x998877 })
  plugin.setup({
    on_highlight = function(groups)
      groups.DiffreelExplorerFileIcon = {}
    end,
  })
  vim.api.nvim_exec_autocmds("ColorSchemePre", { pattern = "no-clear" })
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "no-clear" })
  plugin.setup({ on_highlight = false })
  assert(hl("ExplorerFileIcon").fg == 0x998877)
  plugin.setup({
    on_highlight = function(groups)
      groups.DiffreelExplorerFileIcon = {}
    end,
  })
  vim.cmd("highlight clear")
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "cleared" })
  plugin.setup({ on_highlight = false })
  assert(vim.deep_equal(hl("ExplorerFileIcon"), {}), "reset resurrected a cleared theme definition")
  vim.api.nvim_set_hl(0, "DiffreelExplorerFileIcon", { fg = 0x998877 })
  plugin.setup({
    on_highlight = function(groups)
      for name in pairs(groups) do
        groups[name] = {}
      end
    end,
  })
  vim.cmd("colorscheme default")
  plugin.setup({ on_highlight = false })
  assert(vim.deep_equal(hl("ExplorerFileIcon"), {}), "an all-empty callback masked a real colorscheme clear")
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x654321 })
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
  assert(hl("LineAdd").bg == 0x654321)
  plugin.setup({ on_highlight = callback })
  vim.cmd("highlight clear")
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x334455 })
  vim.api.nvim_set_hl(0, "DiffreelExplorerDirectoryName", { fg = 0x778899 })
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
  assert(hl("ExplorerDirectoryName").fg == 0x778899 and hl("ExplorerDirectoryName").bold)
  assert(hl("ExplorerAddedName").fg == 0x112233)
  assert(hl("LineAdd").bg == 0x334455)
  local config, before = plugin.config, vim.api.nvim_get_hl(0, {})
  for _, bad in ipairs({
    true,
    "bad",
    function(groups)
      groups.DiffreelLineAdd = { bg = "not a color" }
    end,
    function(groups)
      groups.Unknown = {}
    end,
    function(groups)
      groups.DiffreelLineAdd = { default = true }
    end,
    function()
      error("callback failed")
    end,
  }) do
    assert(not pcall(plugin.setup, { on_highlight = bad }))
    assert(plugin.config == config, "invalid setup changed active config")
    assert(vim.deep_equal(before, vim.api.nvim_get_hl(0, {})), "invalid setup partially changed highlights")
  end
end, debug.traceback)
plugin.shutdown()
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
