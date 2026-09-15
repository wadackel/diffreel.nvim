local popup = require("diffreel.popup")
local ui = require("diffreel.ui")
local M = { close = popup.close }
local labels = {
  close = "Close review",
  refresh = "Refresh or retry",
  show_help = "Show help",
  toggle_explorer = "Show or hide explorer",
  cycle_layout = "Cycle diff layout",
  layout_side_by_side = "Side-by-side layout",
  layout_stacked = "Stacked layout",
  layout_inline = "Inline layout",
  next_change = "Next change",
  prev_change = "Previous change",
  next_hunk = "Next hunk across files",
  prev_hunk = "Previous hunk across files",
  first_hunk = "First hunk",
  last_hunk = "Last hunk",
  select_hunk = "Select hunk",
  next_file = "Next file",
  prev_file = "Previous file",
  focus_explorer = "Focus explorer",
  focus_right = "Focus right pane",
  scroll_down = "Scroll diff down",
  scroll_up = "Scroll diff up",
  select_entry = "Select file or toggle folder",
  edit_file = "Open file in a tab",
  collapse_node = "Close folder or parent",
  parent = "Go to parent folder",
  expand_recursive = "Expand subtree",
  collapse_recursive = "Collapse subtree",
  expand_all = "Expand all folders",
  collapse_all = "Collapse all folders",
  toggle_listing = "Toggle file list",
  toggle_compact = "Toggle compact folders",
  show_path = "Show full path",
  yank_path = "Copy relative path",
  yank_path_absolute = "Copy absolute path",
  yank_name = "Copy name",
}

function M.open(view, scope, bindings)
  local lines, key_width = {}, 3
  local highlights = {}
  local function span(row, first, last, group)
    highlights[#highlights + 1] = { row = row, first = first, last = last, group = "DiffreelHelp" .. group }
  end
  for _, binding in ipairs(bindings) do
    key_width = math.max(key_width, vim.fn.strdisplaywidth(binding.lhs))
  end
  lines[1] = "Key" .. string.rep(" ", key_width - 3 + 2) .. "Action"
  span(0, 0, #lines[1], "Header")
  lines[2] = ""
  for _, binding in ipairs(bindings) do
    local first = #binding.lhs + key_width - vim.fn.strdisplaywidth(binding.lhs) + 2
    lines[#lines + 1] = binding.lhs
      .. string.rep(" ", key_width - vim.fn.strdisplaywidth(binding.lhs) + 2)
      .. (type(binding.action) == "function" and "Custom action" or assert(labels[binding.action]))
      .. (
        binding.mode
          and binding.mode ~= "n"
          and (" (" .. (binding.mode == "x" and "Visual" or "Operator-pending") .. ")")
        or ""
      )
    span(#lines - 1, 0, #binding.lhs, "Key")
    span(#lines - 1, first, #lines[#lines], "Action")
  end
  if #bindings == 0 then
    lines[#lines + 1] = "No diffreel mappings in this pane"
    span(#lines - 1, 0, #lines[#lines], "Hint")
  end
  lines[#lines + 1], lines[#lines + 2] = "", "Close help: q / Esc / g?"
  span(#lines - 1, 0, #lines[#lines], "Hint")
  popup.open(
    view,
    "help",
    " " .. ui.label(view.ui_icons, "help", (scope == "explorer" and "Explorer" or "Diff") .. " keys") .. " ",
    lines,
    { "q", "<Esc>", "g?" },
    highlights
  )
end

return M
