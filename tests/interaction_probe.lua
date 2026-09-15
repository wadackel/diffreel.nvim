local probe = assert(loadfile("benchmarks/probe.lua"))(0)
local buf = vim.api.nvim_create_buf(false, true)
local namespace = vim.api.nvim_create_namespace("diffreel")
local entry = { status = "modified" }
local view = {
  explorer_buf = buf,
  selected_path = "file.lua",
  by_path = { ["file.lua"] = entry },
  rows = {
    {
      path = "file.lua",
      text = "  file.lua  M",
      marker_col = 12,
      highlights = { { first = 12, last = 13, group = "DiffreelExplorerModifiedMarker" } },
      entry = entry,
    },
  },
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " root", " HEAD → worktree", "", view.rows[1].text, "" })
vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, { end_row = 1, hl_group = "DiffreelExplorerRootName" })
vim.api.nvim_buf_set_extmark(buf, namespace, 1, 0, { end_row = 2, hl_group = "DiffreelExplorerComparison" })
local marker =
  vim.api.nvim_buf_set_extmark(buf, namespace, 3, 12, { end_col = 13, hl_group = "DiffreelExplorerModifiedMarker" })
local selected = vim.api.nvim_buf_set_extmark(buf, namespace, 3, 0, { line_hl_group = "DiffreelExplorerSelected" })
assert(probe.explorer_matches(view))
vim.api.nvim_buf_set_lines(buf, 5, -1, false, { "stale tail" })
assert(not probe.explorer_matches(view), "Extra stale Explorer lines were accepted")
vim.api.nvim_buf_set_lines(buf, 5, -1, false, {})
_G.diffreel_expected_explorer_headers = { "wrong root" }
assert(not probe.explorer_matches(view), "Wrong Explorer header was accepted")
_G.diffreel_expected_explorer_headers = nil
vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "stale text" })
assert(not probe.explorer_matches(view), "Stale Explorer text was accepted")
vim.api.nvim_buf_set_lines(buf, 3, 4, false, { view.rows[1].text })
vim.api.nvim_buf_set_extmark(
  buf,
  namespace,
  3,
  12,
  { id = marker, end_col = 13, hl_group = "DiffreelExplorerModifiedMarker" }
)
vim.api.nvim_buf_set_extmark(buf, namespace, 4, 0, { id = selected, line_hl_group = "DiffreelExplorerSelected" })
assert(not probe.explorer_matches(view), "Wrong selected row was accepted")
vim.api.nvim_buf_set_extmark(buf, namespace, 3, 0, { id = selected, line_hl_group = "DiffreelExplorerSelected" })
assert(probe.explorer_matches(view))
vim.api.nvim_buf_set_extmark(
  buf,
  namespace,
  3,
  12,
  { id = marker, end_col = 13, hl_group = "DiffreelExplorerDeletedMarker" }
)
assert(not probe.explorer_matches(view), "Wrong file status highlight was accepted")
vim.api.nvim_buf_set_extmark(
  buf,
  namespace,
  3,
  12,
  { id = marker, end_col = 13, hl_group = "DiffreelExplorerModifiedMarker" }
)
view.disk_conflict = true
assert(not probe.explorer_matches(view), "Missing draft message was accepted")
vim.api.nvim_buf_set_lines(buf, 5, -1, false, { "  Unsaved buffer differs ", "  from disk" })
assert(probe.explorer_matches(view))
view.disk_conflict = false
assert(not probe.explorer_matches(view), "Stale draft message was accepted")
vim.api.nvim_buf_set_lines(buf, 5, -1, false, {})
_G.diffreel_expected_line_stats = {
  files = { ["file.lua"] = { additions = 2, deletions = 2 } },
  additions = 2,
  deletions = 2,
}
view.line_stats = true
view.comparison = { generation = 1 }
view.statistics =
  vim.tbl_extend("force", _G.diffreel_expected_line_stats, { generation = 1, complete = true, unavailable = 0 })
view.rows[1].text = "  file.lua +2 -2 M"
view.rows[1].marker_col = #view.rows[1].text - 1
view.rows[1].highlights[1].first = view.rows[1].marker_col
view.rows[1].highlights[1].last = #view.rows[1].text
vim.api.nvim_buf_set_lines(buf, 3, -1, false, { view.rows[1].text, "", "  Saved lines: +2 -2" })
vim.api.nvim_buf_set_extmark(
  buf,
  namespace,
  3,
  view.rows[1].marker_col,
  { id = marker, end_col = #view.rows[1].text, hl_group = "DiffreelExplorerModifiedMarker" }
)
vim.api.nvim_buf_set_extmark(buf, namespace, 3, 0, { id = selected, line_hl_group = "DiffreelExplorerSelected" })
assert(probe.explorer_matches(view), "Valid saved counts were rejected")
view.statistics = vim.tbl_extend("force", view.statistics, { generation = 0 })
assert(not probe.explorer_matches(view), "Stale-generation counts were accepted")
view.statistics.generation = 1
vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "  Saved lines: +99 -99" })
assert(not probe.explorer_matches(view), "Incorrect totals were accepted")
vim.api.nvim_buf_set_lines(buf, 5, 6, false, { "  Saved lines: +2 -2" })
assert(probe.explorer_matches(view), "Restored saved counts were rejected")
view.statistics.files = { ["file.lua"] = { additions = 99, deletions = 99 } }
assert(not probe.explorer_matches(view), "Incorrect per-file counts were accepted")
print("Explorer readiness verification passed")
vim.cmd("qa!")
