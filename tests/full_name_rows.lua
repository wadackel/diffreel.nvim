vim.opt.rtp:prepend(vim.fn.getcwd())
local explorer = require("diffreel.explorer")
local plugin = require("diffreel")
plugin.setup({ watch = false })
local entry = { path = "long-directory/子ディレクトリ/long-name\t.test.lua", status = "added" }
local stats = { [entry.path] = { additions = 12, deletions = 3 } }
for _, icons in ipairs({ false, true }) do
  package.loaded["nvim-web-devicons"] = icons and {
    get_icon = function()
      return "λ", "Special"
    end,
  } or nil
  package.preload["nvim-web-devicons"] = function()
    error("No icons")
  end
  for _, settings in ipairs({ {}, { compact = true }, { mode = "list" } }) do
    settings.status_icons = { added = "追加" }
    local narrow = explorer.rows({ entry }, {}, 16, nil, stats, settings)
    local wide = explorer.rows({ entry }, {}, 160, nil, stats, settings)
    for i, row in ipairs(narrow) do
      assert(row.truncated, "Expected a clipped name")
      assert(row.full.text:find(explorer.display(settings.mode == "list" and entry.path or row.name), 1, true))
      assert(not wide[i].truncated and wide[i].full.text == wide[i].text)
      local groups = {}
      for _, span in ipairs(row.full.highlights) do
        assert(span.first >= 0 and span.last <= #row.full.text)
        assert(vim.str_utfindex(row.full.text, "utf-8", span.first, true) >= 0)
        assert(vim.str_utfindex(row.full.text, "utf-8", span.last, true) >= 0)
        groups[span.group] = row.full.text:sub(span.first + 1, span.last)
      end
      if row.entry then
        assert(groups.DiffreelExplorerAddedName == explorer.display(settings.mode == "list" and entry.path or row.name))
        assert(groups.DiffreelExplorerStatsAdd == "+12" and groups.DiffreelExplorerStatsDelete == "-3")
        assert(groups.DiffreelExplorerAddedMarker == "追加")
      elseif settings.compact then
        assert(groups.DiffreelExplorerDirectoryName == "long-directory/子ディレクトリ")
      end
    end
  end
end
print("Full name rows passed")
vim.cmd("qa!")
