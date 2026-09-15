local M = {}

function M.label(file)
  if file.status == "A" then
    return "+ " .. file.path
  end
  return file.path
end

function M.filter(files, query)
  local matches = {}
  for _, file in ipairs(files) do
    if file.path:find(query, 1, true) then
      matches[#matches + 1] = file
    end
  end
  return matches
end

return M
