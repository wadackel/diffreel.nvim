vim.opt.rtp:prepend(vim.fn.getcwd())
local explorer = require("diffreel.explorer")
local plugin = require("diffreel")
local ok, err = xpcall(function()
  plugin.setup({ watch = false })
  local entry = { path = "長い/子/名前\t.lua", status = "added" }
  for _, settings in ipairs({ {}, { compact = true }, { mode = "list" } }) do
    for _, width in ipairs({ 12, 60 }) do
      local rows = explorer.rows(
        { entry },
        {},
        width,
        nil,
        { [entry.path] = { additions = 12, deletions = 3 } },
        settings
      )
      for _, row in ipairs(rows) do
        assert(row.highlights, "row has no separate highlight ranges")
        local last, groups = 0, {}
        for _, span in ipairs(row.highlights) do
          assert(span.first >= last and span.last <= #row.text and span.last > span.first)
          assert(vim.str_utfindex(row.text, "utf-8", span.first, true) >= 0)
          assert(vim.str_utfindex(row.text, "utf-8", span.last, true) >= 0)
          groups[span.group] = row.text:sub(span.first + 1, span.last)
          last = span.last
        end
        if row.entry then
          assert(groups.DiffreelExplorerAddedMarker == "A")
          assert(groups.DiffreelExplorerStatsAdd == "+12")
          assert(groups.DiffreelExplorerStatsDelete == "-3")
          assert(groups.DiffreelExplorerAddedName)
        else
          assert(groups.DiffreelExplorerDirectoryName)
          assert(groups.DiffreelExplorerDirectoryIcon == "▾")
        end
      end
    end
  end
  local view = { id = 987 }
  require("diffreel.help").open(view, "explorer", { { lhs = "é", action = "close", mode = "n" } })
  local marks = vim.api.nvim_buf_get_extmarks(view.help.buf, -1, 0, -1, { details = true })
  local found = {}
  for _, mark in ipairs(marks) do
    found[mark[4].hl_group] = true
  end
  assert(found.DiffreelHelpKey and found.DiffreelHelpAction and found.DiffreelHelpHint)
  assert(vim.wo[view.help.win].winhighlight:find("NormalFloat:DiffreelHelpNormal", 1, true))
  require("diffreel.popup").close(view)
  require("diffreel.popup").open(view, "path_popup", "Full path", { "/a/file", "", "Close path" }, { "q" })
  marks = vim.api.nvim_buf_get_extmarks(view.path_popup.buf, -1, 0, -1, { details = true })
  assert(marks[1] and marks[1][4].hl_group == "DiffreelPathText", "path text has no highlight")
  require("diffreel.popup").close(view, "path_popup")
end, debug.traceback)
plugin.shutdown()
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
