local M = { generation = 0 }
local owned = {}
local validation = vim.api.nvim_create_namespace("diffreel.highlight_validation")

local function read(name)
  return vim.api.nvim_get_hl(0, { name = name, create = false })
end

local function color(name, key)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false, create = false })
  return hl[hl.reverse and (key == "bg" and "fg" or "bg") or key]
end

local function brighter(value)
  local factor = vim.o.background == "light" and 0.92 or 1.4
  local function channel(shift)
    return math.min(255, math.floor((math.floor(value / 2 ^ shift) % 256) * factor))
  end
  return channel(16) * 65536 + channel(8) * 256 + channel(0)
end

local statuses = {
  Added = "DiffreelAdded",
  Modified = "DiffreelModified",
  Deleted = "DiffreelDeleted",
  Renamed = "DiffreelModified",
  Metadata = "DiffreelModified",
  TypeChange = "DiffreelModified",
  Limited = "DiagnosticWarn",
  Missing = "DiagnosticWarn",
  Unchanged = "DiffreelDim",
  BufferOnly = "DiffreelModified",
  Unknown = "DiffreelModified",
}

function M.defaults()
  local added = color("DiffAdd", "bg") or 0x1c394b
  local deleted = color("DiffDelete", "bg") or 0x513351
  local groups = {
    DiffreelLineAdd = { bg = added },
    DiffreelLineDelete = { bg = deleted },
    DiffreelTextAdd = { bg = brighter(added) },
    DiffreelTextDelete = { bg = brighter(deleted) },
    DiffreelFiller = { fg = color("NonText", "fg") or color("Comment", "fg"), bg = color("Normal", "bg") },
    DiffreelSelected = { bg = color("Visual", "bg") or color("CursorLine", "bg"), bold = true },
  }
  local links = {
    Title = "Title",
    Dim = "Comment",
    Added = "DiagnosticOk",
    Deleted = "DiagnosticError",
    Modified = "DiagnosticWarn",
    ExplorerTitle = "DiffreelTitle",
    ExplorerFileCount = "DiffreelDim",
    ExplorerRootName = "Directory",
    ExplorerComparison = "DiffreelDim",
    ExplorerDirectoryName = "Directory",
    ExplorerDirectoryIcon = "Directory",
    ExplorerSelected = "DiffreelSelected",
    DiffFolded = "DiffreelDim",
    InlineDeleteNumber = "DiffreelLineDelete",
    DiffWinbarRevision = "DiffreelDim",
    DiffWinbarState = "DiffreelDim",
  }
  for _, part in ipairs({ "Normal", "NormalNC", "WinSeparator", "WinBar", "WinBarNC" }) do
    links["Explorer" .. part], links["Diff" .. part] = part, part
  end
  links.ExplorerCursorLine = "CursorLine"
  for _, part in ipairs({ "LineNr", "CursorLineNr", "FoldColumn" }) do
    links["Diff" .. part] = part
  end
  for _, scope in ipairs({ "Help", "Path" }) do
    links[scope .. "Normal"] = "NormalFloat"
    links[scope .. "Border"] = "FloatBorder"
    links[scope .. "Title"] = "FloatTitle"
  end
  for name, target in pairs(links) do
    groups["Diffreel" .. name] = { link = target }
  end
  for _, name in ipairs({
    "ExplorerFileName",
    "ExplorerFileIcon",
    "ExplorerIndent",
    "ExplorerStatsAdd",
    "ExplorerStatsDelete",
    "ExplorerStatsPending",
    "ExplorerStatsUnavailable",
    "ExplorerSummary",
    "ExplorerDetail",
    "ExplorerLoading",
    "ExplorerEmpty",
    "ExplorerError",
    "ExplorerConflict",
    "ExplorerPaused",
    "HelpHeader",
    "HelpKey",
    "HelpAction",
    "HelpHint",
    "PathText",
    "DiffWinbarPath",
  }) do
    groups["Diffreel" .. name] = {}
  end
  for status, target in pairs(statuses) do
    local base = "DiffreelExplorer" .. status
    groups[base] = { link = target }
    groups[base .. "Name"] = { link = "DiffreelExplorerFileName" }
    groups[base .. "Icon"] = { link = "DiffreelExplorerFileIcon" }
    groups[base .. "Marker"] = { link = base }
  end
  return groups
end

function M.before_colorscheme()
  for name, state in pairs(owned) do
    -- Leaving a masked external value empty makes a no-clear theme indistinguishable from :highlight clear.
    if state.external and not next(state.installed) and vim.deep_equal(read(name), state.installed) then
      vim.api.nvim_set_hl(0, name, state.base)
      state.installed = read(name)
    end
  end
end

function M.prepare(callback, theme)
  assert(
    callback == nil or callback == false or type(callback) == "function",
    "diffreel: on_highlight must be a function or false"
  )
  local defaults, groups, states, current_groups = M.defaults(), {}, {}, {}
  local cleared = false
  for name in pairs(defaults) do
    local current, previous = read(name), owned[name]
    current_groups[name] = current
    if theme and previous and next(previous.installed) and not next(current) then
      cleared = true
    end
  end
  for name, definition in pairs(defaults) do
    local current, previous = current_groups[name], owned[name]
    local base, external = current, next(current) ~= nil
    -- An empty callback result also compares equal after :highlight clear; its displaced theme must not return.
    if previous and vim.deep_equal(current, previous.installed) and not (cleared and not next(current)) then
      base, external = previous.base, previous.external
    elseif previous and not theme then
      external = true
    end
    groups[name] = vim.deepcopy(external and base or definition)
    states[name] = { base = vim.deepcopy(base), external = external }
  end
  local before, references = vim.deepcopy(groups), vim.tbl_extend("force", {}, groups)
  if callback then
    callback(groups)
  end
  for name, definition in pairs(groups) do
    assert(defaults[name], "diffreel: unknown highlight group " .. tostring(name))
    assert(type(definition) == "table", "diffreel: highlight " .. name .. " must be a table")
    assert(
      definition.default == nil and definition.force == nil,
      "diffreel: highlight default/force are managed by diffreel"
    )
  end
  for name, state in pairs(states) do
    local definition = groups[name]
    state.explicit = state.external
      or (definition ~= nil and (definition ~= references[name] or not vim.deep_equal(definition, before[name])))
    state.definition = vim.deepcopy(definition or before[name])
    -- Validation in namespace zero would publish half a callback before a bad color is discovered.
    local ok, err = pcall(vim.api.nvim_set_hl, validation, name, state.definition)
    assert(ok, "diffreel: highlight " .. name .. ": " .. tostring(err))
  end
  return states
end

function M.apply(states)
  for name, state in pairs(states) do
    vim.api.nvim_set_hl(0, name, state.definition)
    state.installed = read(name)
    state.definition = nil
  end
  owned = states
  M.generation = M.generation + 1
end

function M.icon(group, provider)
  local current, seen = group, {}
  while current and not seen[current] do
    seen[current] = true
    local definition, state = read(current), owned[current]
    if state and (state.explicit or not vim.deep_equal(definition, state.installed)) then
      return group
    end
    current = definition.link
  end
  return provider or group
end

function M.status(entry)
  local status = entry.buffer_only and "BufferOnly"
    or ({
      added = "Added",
      modified = "Modified",
      deleted = "Deleted",
      renamed = "Renamed",
      metadata = "Metadata",
      typechange = "TypeChange",
      limited = "Limited",
      missing = "Missing",
      unchanged = "Unchanged",
    })[entry.status]
    or "Unknown"
  return "DiffreelExplorer" .. status
end

return M
