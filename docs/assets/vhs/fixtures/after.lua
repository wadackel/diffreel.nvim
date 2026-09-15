local M = {}

function M.label(file)
  local marks = { A = "+", M = "~" }
  local mark = marks[file.status] or "-"
  return mark .. " " .. file.path
end

function M.filter(files, query)
  query = query:lower()
  local matches = {}
  for _, file in ipairs(files) do
    local path = file.path:lower()
    if path:find(query, 1, true) then
      matches[#matches + 1] = file
    end
  end
  return matches
end

return M
