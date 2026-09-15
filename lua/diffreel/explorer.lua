local M = {}
local highlights = require("diffreel.highlights")
local options = require("diffreel.options")

function M.display(text)
  local escapes = { ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
  return (
    text:gsub("[%z\1-\31\127\\]", function(char)
      return escapes[char] or ("\\x%02X"):format(char:byte())
    end)
  )
end

local function shorten(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local length = math.max(0, width - 1)
  local value = vim.fn.strcharpart(text, 0, length)
  while vim.fn.strdisplaywidth(value) > width - 1 and length > 0 do
    length = length - 1
    value = vim.fn.strcharpart(text, 0, length)
  end
  return value .. "…"
end

function M.build(entries)
  local root = { children = {}, path = "", branch = true }
  local nodes = { [""] = root }
  for _, entry in ipairs(entries) do
    local parent, full = root, ""
    local parts = vim.split(entry.path, "/", { plain = true })
    for i, name in ipairs(parts) do
      full = full == "" and name or (full .. "/" .. name)
      parent.children[name] = parent.children[name]
        or {
          name = name,
          path = full,
          parent_path = parent.path,
          children = {},
        }
      parent.branch = true
      parent = parent.children[name]
      nodes[full] = parent
      if i == #parts then
        parent.entry = entry
      end
    end
  end
  local ordered = {}
  local function sort(node)
    node.children = vim.tbl_values(node.children)
    table.sort(node.children, function(a, b)
      if (a.entry == nil) ~= (b.entry == nil) then
        return a.entry == nil
      end
      return a.name < b.name
    end)
    if node.entry then
      ordered[#ordered + 1] = node.entry
    end
    for _, child in ipairs(node.children) do
      sort(child)
    end
  end
  sort(root)
  return { root = root, nodes = nodes, entries = ordered }
end

local function parent_path(path)
  return path:match("^(.*)/[^/]+$") or ""
end

function M.reveal(collapsed, path)
  local changed = false
  local parent = parent_path(path)
  while parent ~= "" do
    changed = changed or not not collapsed[parent]
    collapsed[parent] = nil
    parent = parent_path(parent)
  end
  return changed
end

function M.ordered(tree, mode)
  if mode ~= "list" then
    return tree.entries
  end
  if not tree.list_entries then
    tree.list_entries = vim.list_slice(tree.entries)
    table.sort(tree.list_entries, function(a, b)
      return a.path < b.path
    end)
  end
  return tree.list_entries
end

function M.cursor_path(rows, path)
  local visible = {}
  for _, row in ipairs(rows) do
    visible[row.path] = row.path
    for _, part in ipairs(row.paths or {}) do
      visible[part] = row.path
    end
  end
  while path and path ~= "" do
    if visible[path] then
      return visible[path]
    end
    for _, row in ipairs(rows) do
      if row.list and row.path:sub(1, #path + 1) == path .. "/" then
        return row.path
      end
    end
    path = parent_path(path)
  end
  return rows[1] and rows[1].path or nil
end

function M.act(tree, collapsed, path, action, row)
  if row and row.list then
    return
  end
  local node = path and tree.nodes[path]
  local target = node
  local parent = row and row.parent_path or (node and node.parent_path)
  if action == "expand_all" or action == "collapse_all" then
    target = tree.root
    if not next(target.children) then
      return
    end
  elseif not node then
    return
  elseif action == "parent" then
    return parent ~= "" and parent or nil
  elseif action == "toggle" then
    if node.branch then
      collapsed[path] = not collapsed[path] or nil
      return path
    end
    return
  elseif action == "collapse_node" then
    if not node.branch or collapsed[path] then
      target = tree.nodes[parent]
    end
    if not target or target.path == "" then
      return
    end
    collapsed[target.path] = true
    return target.path
  elseif action == "expand_recursive" or action == "collapse_recursive" then
    target = node.branch and node or tree.nodes[parent]
  else
    error("Unknown tree action: " .. action)
  end
  if not target then
    return
  end
  local closed = action == "collapse_all" or action == "collapse_recursive"
  local function visit(current)
    if current.branch and current.path ~= "" then
      collapsed[current.path] = closed or nil
    end
    for _, child in pairs(current.children) do
      visit(child)
    end
  end
  visit(target)
  if action == "collapse_recursive" and target.path ~= "" then
    return target.path
  end
  return path or ""
end

local function display_state()
  local state = { cell_widths = vim.fn.getcellwidths() }
  for _, name in ipairs({
    "ambiwidth",
    "emoji",
    "isprint",
    "display",
    "arabicshape",
    "termbidi",
    "tabstop",
    "vartabstop",
    "list",
    "listchars",
  }) do
    state[name] = vim.api.nvim_get_option_value(name, {})
  end
  return state
end

local function icons_match(rows, provider)
  if provider then
    for _, row in ipairs(rows) do
      if row.entry and not row.branch then
        local icon, group = provider.get_icon(row.name, nil, { default = true })
        if icon ~= row.icon or group ~= row.icon_group then
          return false
        end
      end
    end
  end
  return true
end

local function span(ranges, first, last, group, icon)
  if last > first then
    ranges[#ranges + 1] = { first = first, last = last, group = group, icon = icon }
  end
end

function M.rows(entries, collapsed, width, tree, statistics, settings)
  settings = settings or {}
  local mode, compact = settings.mode or "tree", settings.compact or false
  local status_icons = options.status_icons(settings.status_icons)
  local has_icons, icons = pcall(require, "nvim-web-devicons")
  tree = tree or M.build(entries)
  for path, closed in pairs(collapsed) do
    local node = tree.nodes[path]
    if not closed or not node or not node.branch or path == "" then
      collapsed[path] = nil
    end
  end
  local rendered = tree.rendered
  local icon_source = has_icons and icons or nil
  local display = display_state()
  if
    rendered
    and rendered.width == width
    and rendered.mode == mode
    and rendered.compact == compact
    and rendered.statistics == statistics
    and rendered.icons == icon_source
    and vim.deep_equal(rendered.status_icons, status_icons)
    and vim.deep_equal(rendered.collapsed, collapsed)
    and vim.deep_equal(rendered.display, display)
    and icons_match(rendered.rows, icon_source)
  then
    return rendered.rows, tree
  end
  local rows = {}
  local function file_row(child, depth, list)
    local prefix = " " .. string.rep("  ", depth)
    local branch = not list and child.branch
    local marker = child.entry.buffer_only and status_icons.buffer_only
      or status_icons[child.entry.status]
      or status_icons.unknown
    local marker_width = vim.fn.strdisplaywidth(marker)
    local icon, icon_group
    if branch then
      icon = collapsed[child.path] and "▸" or "▾"
    elseif has_icons then
      icon, icon_group = icons.get_icon(child.name, nil, { default = true })
    end
    local icon_col = #prefix
    local lead = prefix .. (icon and (icon .. " ") or "  ")
    local counts = ""
    if statistics then
      local value = statistics[child.path]
      counts = child.entry.buffer_only and "— "
        or not value and "… "
        or value.reason == "binary" and "bin "
        or value.reason and "— "
        or ("+" .. value.additions .. " -" .. value.deletions .. " ")
    end
    local name = M.display(list and child.path or child.name)
    if width then
      name = shorten(name, math.max(1, width - vim.fn.strdisplaywidth(lead .. counts) - marker_width - 3))
    end
    local text = lead .. name
    local ranges, group = {}, highlights.status(child.entry)
    span(ranges, 0, #prefix, "DiffreelExplorerIndent")
    if icon then
      span(
        ranges,
        icon_col,
        icon_col + #icon,
        branch and "DiffreelExplorerDirectoryIcon" or (group .. "Icon"),
        not branch
      )
    end
    span(ranges, #lead, #text, group .. "Name")
    text = text
      .. string.rep(" ", math.max(2, (width or 0) - vim.fn.strdisplaywidth(text .. counts) - marker_width - 1))
      .. counts
    local count_col = #text - #counts
    local add, delete = counts:match("^(%+%d+) (%-%d+)")
    if add then
      span(ranges, count_col, count_col + #add, "DiffreelExplorerStatsAdd")
      span(ranges, count_col + #add + 1, count_col + #add + 1 + #delete, "DiffreelExplorerStatsDelete")
    elseif counts ~= "" then
      span(
        ranges,
        count_col,
        #text - 1,
        counts == "… " and "DiffreelExplorerStatsPending" or "DiffreelExplorerStatsUnavailable"
      )
    end
    span(ranges, #text, #text + #marker, group .. "Marker")
    rows[#rows + 1] = {
      text = text .. marker,
      highlights = ranges,
      marker_col = #text,
      icon_col = icon_col,
      name_col = #lead,
      icon_group = icon_group,
      icon = icon,
      path = child.path,
      name = child.name,
      branch = branch,
      parent_path = child.parent_path,
      list = list,
      entry = child.entry,
    }
  end
  local function visit(node, depth)
    for _, first in ipairs(node.children) do
      local child = first
      if child.entry then
        file_row(child, depth, false)
      else
        local label, paths = child.name, { child.path }
        while compact and not collapsed[child.path] and #child.children == 1 and not child.children[1].entry do
          child = child.children[1]
          label = label .. "/" .. child.name
          paths[#paths + 1] = child.path
        end
        local prefix = " " .. string.rep("  ", depth)
        local lead = prefix .. (collapsed[child.path] and "▸ " or "▾ ")
        local name = M.display(label)
        if width then
          name = shorten(name, math.max(1, width - vim.fn.strdisplaywidth(lead)))
        end
        local ranges = {}
        span(ranges, 0, #prefix, "DiffreelExplorerIndent")
        span(ranges, #prefix, #lead - 1, "DiffreelExplorerDirectoryIcon")
        span(ranges, #lead, #lead + #name, "DiffreelExplorerDirectoryName")
        rows[#rows + 1] = {
          text = lead .. name,
          highlights = ranges,
          path = child.path,
          name = child.name,
          paths = paths,
          parent_path = first.parent_path,
          branch = true,
          directory = true,
        }
      end
      if child.branch and not collapsed[child.path] then
        visit(child, depth + 1)
      end
    end
  end
  if mode == "list" then
    for _, entry in ipairs(M.ordered(tree, mode)) do
      file_row(tree.nodes[entry.path], 0, true)
    end
  else
    visit(tree.root, 0)
  end
  tree.rendered = {
    width = width,
    mode = mode,
    compact = compact,
    statistics = statistics,
    icons = icon_source,
    status_icons = status_icons,
    display = display,
    collapsed = vim.deepcopy(collapsed),
    rows = rows,
  }
  return rows, tree
end

return M
