local M = {}
local defaults = {
  changes = "",
  repository = "",
  commit = "",
  index = "",
  worktree = "",
  empty = "∅",
  pull_request = "",
  unsaved = "",
  directory_closed = "󰉋",
  directory_open = "󰝰",
  loading = "",
  paused = "",
  warning = "",
  error = "",
  clean = "",
  help = "",
  path = "",
}

function M.resolve(value, base)
  value = value == nil and {} or value
  assert(type(value) == "table", "diffreel: ui_icons must be a table")
  local result = vim.tbl_extend("force", defaults, base or {}, value)
  for name, icon in pairs(result) do
    assert(defaults[name] ~= nil, "diffreel: unknown ui_icons key " .. tostring(name))
    assert(
      type(icon) == "string" and icon ~= "" and not icon:find("[%z\1-\31\127]") and not icon:find("\194[\128-\159]"),
      "diffreel: ui_icons." .. name .. " must be a nonempty string without control characters"
    )
  end
  return result
end

function M.icon(icons, name)
  return (icons or defaults)[name]
end

function M.prefix(icon, text)
  return icon .. " " .. text
end

function M.label(icons, name, text)
  return M.prefix(M.icon(icons, name), text)
end

function M.winbar(text)
  return (text:gsub("%%", "%%%%"))
end

function M.endpoint(icons, revision, label)
  if revision == "worktree" then
    return M.label(icons, "worktree", "Worktree")
  elseif revision == ":0" then
    return M.label(icons, "index", "Index")
  elseif revision == "" then
    return M.label(icons, "empty", "Empty tree")
  end
  return M.label(icons, "commit", label or revision:sub(1, 8))
end

function M.wrap(text, width)
  local result, first = {}, 1
  repeat
    local first_width = math.max(1, vim.fn.strdisplaywidth(vim.fn.strcharpart(text:sub(first), 0, 1)))
    local prefix = string.rep(" ", math.min(#result == 0 and 1 or 2, math.max(0, width - first_width)))
    local cursor, last, space = first, first - 1, nil
    while cursor <= #text do
      local char = vim.fn.strcharpart(text:sub(cursor), 0, 1)
      local finish = cursor + #char - 1
      local fits = vim.fn.strdisplaywidth(prefix .. text:sub(first, finish)) <= width
      if not fits and cursor > first then
        break
      end
      last, cursor = finish, finish + 1
      if char == " " then
        space = finish
      end
      if not fits then
        break
      end
    end
    if cursor <= #text and space then
      last = space
    end
    result[#result + 1] = { text = prefix .. text:sub(first, last), prefix = #prefix, first = first - 1, last = last }
    first = last + 1
  until first > #text
  return result
end

function M.anchor(rows, row, col)
  local part = rows and rows[row]
  if part then
    return { id = part.id, offset = part.first + math.max(0, col - part.prefix) }
  end
end

function M.locate(rows, anchor)
  if not anchor then
    return
  end
  local target, found
  for row, part in pairs(rows) do
    if part.id == anchor.id then
      if anchor.offset >= part.first and anchor.offset < part.last then
        target, found = row, part
        break
      elseif not found or part.first > found.first then
        target, found = row, part
      end
    end
  end
  if found then
    local col = found.prefix + math.max(0, math.min(anchor.offset - found.first, found.last - found.first - 1))
    while col > found.prefix do
      local byte = found.text:byte(col + 1)
      if not byte or byte < 128 or byte >= 192 then
        break
      end
      col = col - 1
    end
    return target, col
  end
end

return M
