local popup = require("diffreel.popup")
local M = { close = popup.close }

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
      .. (type(binding.action) == "function" and "Custom callback" or binding.action)
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
    " diffreel · " .. (scope == "explorer" and "Explorer" or "Diff") .. " keys ",
    lines,
    { "q", "<Esc>", "g?" },
    highlights
  )
end

return M
