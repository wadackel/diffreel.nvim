local spinner = require("diffreel.spinner")
local M = {}
local status_icons = {
  added = "",
  modified = "",
  deleted = "",
  renamed = "",
  metadata = "~",
  limited = "!",
  typechange = "T",
  unchanged = "=",
  missing = "∅",
  buffer_only = "*",
  unknown = "?",
}

function M.status_icons(value, base)
  value = value == nil and {} or value
  assert(type(value) == "table", "diffreel: explorer.status_icons must be a table")
  local result = vim.tbl_extend("force", status_icons, base or {}, value)
  for name, icon in pairs(result) do
    assert(status_icons[name] ~= nil, "diffreel: unknown explorer.status_icons key " .. tostring(name))
    assert(
      type(icon) == "string" and icon ~= "" and not icon:find("[%z\1-\31\127]") and not icon:find("\194[\128-\159]"),
      "diffreel: explorer.status_icons." .. name .. " must be a nonempty string without control characters"
    )
  end
  return result
end

function M.dimension(value, name)
  assert(
    type(value) == "number" and value > 0 and value <= 2147483647 and value % 1 == 0,
    "diffreel: explorer." .. name .. " must be a positive integer"
  )
  return value
end

local function string_option(value, name, empty)
  assert(
    type(value) == "string" and not value:find("\0", 1, true) and (empty or value ~= ""),
    "diffreel: " .. name .. " must be a " .. (empty and "" or "nonempty ") .. "string without NUL"
  )
end

function M.explorer(value, base)
  value = value == nil and {} or value
  assert(type(value) == "table", "diffreel: explorer must be a table")
  local result = vim.tbl_extend(
    "force",
    { mode = "tree", compact = false, full_name = true, visible = true, position = "left", height = 10 },
    base or {},
    value
  )
  for name in pairs(result) do
    assert(
      vim.tbl_contains(
        { "mode", "compact", "full_name", "visible", "position", "height", "width", "status_icons" },
        name
      ),
      "diffreel: unknown explorer option " .. tostring(name)
    )
  end
  assert(result.mode == "tree" or result.mode == "list", "diffreel: explorer.mode must be tree or list")
  assert(vim.tbl_contains({ "left", "right", "top", "bottom" }, result.position), "diffreel: invalid explorer.position")
  for _, name in ipairs({ "compact", "full_name", "visible" }) do
    assert(type(result[name]) == "boolean", "diffreel: explorer." .. name .. " must be boolean")
  end
  for _, name in ipairs({ "width", "height" }) do
    local size = result[name]
    if size ~= nil and type(size) ~= "function" then
      M.dimension(size, name)
    end
  end
  result.status_icons = M.status_icons(value.status_icons, base and base.status_icons)
  return result
end

function M.spinner(value, base)
  if value == nil then
    return base == nil and vim.deepcopy(spinner.defaults) or base
  end
  if value == false then
    return false
  end
  assert(type(value) == "table", "diffreel: spinner must be a table or false")
  local result = vim.tbl_extend("force", spinner.defaults, type(base) == "table" and base or {}, value)
  for name in pairs(result) do
    assert(name == "frames" or name == "interval", "diffreel: unknown spinner option " .. tostring(name))
  end
  assert(
    vim.islist(result.frames) and #result.frames > 0,
    "diffreel: spinner.frames must be a nonempty array of strings"
  )
  local width
  for _, frame in ipairs(result.frames) do
    string_option(frame, "spinner.frames entry", false)
    assert(
      not frame:find("[%z\1-\31\127]") and not frame:find("\194[\128-\159]"),
      "diffreel: spinner.frames entries must not contain control characters"
    )
    local size = vim.fn.strdisplaywidth(frame)
    -- Frames of differing widths shift the label sideways on every tick.
    assert(width == nil or size == width, "diffreel: spinner.frames must share one display width")
    width = size
  end
  assert(
    type(result.interval) == "number" and result.interval % 1 == 0 and result.interval >= 16,
    "diffreel: spinner.interval must be an integer of at least 16"
  )
  result.frames = vim.deepcopy(result.frames)
  return result
end

function M.validate(opts)
  assert(type(opts) == "table", "diffreel: options must be a table")
  assert(
    opts.layout == nil or vim.tbl_contains({ "side_by_side", "stacked", "inline" }, opts.layout),
    "diffreel: layout must be side_by_side, stacked or inline"
  )
  if opts.pr ~= nil then
    if type(opts.pr) == "number" then
      assert(
        opts.pr > 0 and opts.pr % 1 == 0 and opts.pr <= 9007199254740991,
        "diffreel: pr must be a positive integer"
      )
    else
      string_option(opts.pr, "pr", false)
      assert(
        opts.pr:match("^[1-9]%d*$") or opts.pr:match("^https://[%w.-]+/[%w_.-]+/[%w_.-]+/pull/[1-9]%d*"),
        "diffreel: pr must be a positive number or GitHub PR URL"
      )
    end
    for _, name in ipairs({ "left", "right", "merge_base", "untracked" }) do
      assert(opts[name] == nil, "diffreel: pr cannot be combined with " .. name)
    end
  end
  if opts.explorer ~= nil then
    M.explorer(opts.explorer)
  end
  for _, name in ipairs({ "paths", "exclude" }) do
    if opts[name] ~= nil then
      assert(type(opts[name]) == "table" and vim.islist(opts[name]), "diffreel: " .. name .. " must be an array")
      for _, value in ipairs(opts[name]) do
        string_option(value, name, false)
      end
    end
  end
  for _, name in ipairs({ "untracked", "line_stats", "merge_base" }) do
    assert(opts[name] == nil or type(opts[name]) == "boolean", "diffreel: " .. name .. " must be boolean")
  end
  for _, name in ipairs({ "left", "right", "root" }) do
    if opts[name] ~= nil then
      string_option(opts[name], name, name ~= "root")
    end
  end
  if opts.selected_file ~= nil and opts.selected_file ~= false then
    string_option(opts.selected_file, "selected_file", false)
  end
  if opts.file ~= nil and type(opts.file) ~= "boolean" then
    string_option(opts.file, "file", false)
  end
end

local function merge_range(revision)
  local depth, i = 0, 1
  while i <= #revision do
    local char = revision:sub(i, i)
    if char == "{" then
      depth = depth + 1
    elseif char == "}" then
      depth = math.max(0, depth - 1)
    elseif depth == 0 and revision:sub(i, i + 2) == "..." then
      return revision:sub(1, i - 1), revision:sub(i + 3)
    end
    i = i + 1
  end
end

function M.normalize(opts, config)
  M.validate(opts)
  assert(opts.ui_icons == nil, "diffreel: ui_icons is a setup() option")
  assert(opts.spinner == nil, "diffreel: spinner is a setup() option")
  config = config or {}
  local function value(name, fallback)
    if opts[name] ~= nil then
      return opts[name]
    elseif config[name] ~= nil then
      return config[name]
    end
    return fallback
  end
  local result = {
    root = opts.root,
    layout = value("layout", "side_by_side"),
    pr = opts.pr,
    left = opts.left or "HEAD",
    right = opts.right or "worktree",
    paths = vim.deepcopy(value("paths", {})),
    untracked = value("untracked", true),
    selected_file = value("selected_file", nil),
    file = opts.file,
    line_stats = value("line_stats", false),
    merge_base = opts.merge_base or false,
    explorer = M.explorer(opts.explorer, config.explorer),
  }
  if opts.file then
    assert(opts.paths == nil and opts.exclude == nil, "diffreel: file cannot be combined with paths or exclude")
    result.paths, result.untracked = {}, true
    if not opts.explorer or opts.explorer.visible == nil then
      result.explorer.visible = false
    end
  else
    for _, pattern in ipairs(value("exclude", {})) do
      result.paths[#result.paths + 1] = ":(exclude,glob)" .. pattern
    end
  end
  local left, right = merge_range(result.left)
  if left ~= nil then
    assert(opts.right == nil, "diffreel: a triple-dot range cannot have another right revision")
    assert(not merge_range(right), "diffreel: only one triple-dot range is allowed")
    result.left = left == "" and "HEAD" or left
    result.right = right == "" and "worktree" or right
    result.merge_base = true
  end
  assert(result.left ~= "worktree", "diffreel: worktree is only supported on the right")
  if opts.pr ~= nil then
    result.left, result.right, result.untracked = "", "", false
  end
  if result.merge_base then
    assert(
      result.left ~= "" and result.left ~= ":0" and result.right ~= "" and result.right ~= ":0",
      "diffreel: merge-base requires committed revisions"
    )
  end
  return result
end

function M.parse(args)
  local result, revisions, mode = {}, {}, nil
  local i = 1
  while i <= #args do
    local arg = args[i]
    if arg == "--" then
      result.paths = {}
      for j = i + 1, #args do
        result.paths[#result.paths + 1] = args[j]
      end
      break
    elseif arg == "--staged" or arg == "--cached" or arg == "--unstaged" then
      local next_mode = arg == "--unstaged" and "unstaged" or "staged"
      assert(not mode or mode == next_mode, "diffreel: --staged and --unstaged cannot be combined")
      mode = next_mode
    elseif arg == "--stat" or arg == "--no-stat" then
      result.line_stats = arg == "--stat"
    elseif arg == "--no-untracked" then
      result.untracked = false
    elseif arg == "--merge-base" then
      result.merge_base = true
    elseif arg == "--file" then
      result.file = true
    elseif arg == "--help" then
      result.help = true
    elseif
      vim.tbl_contains({ "--list", "--tree", "--compact", "--no-compact", "--explorer", "--no-explorer" }, arg)
    then
      result.explorer = result.explorer or {}
      if arg == "--list" or arg == "--tree" then
        result.explorer.mode = arg:sub(3)
      elseif arg == "--compact" or arg == "--no-compact" then
        result.explorer.compact = arg == "--compact"
      else
        result.explorer.visible = arg == "--explorer"
      end
    elseif arg:sub(1, 1) == "-" then
      local name, value = arg:match("^(%-%-[%w-]+)=(.*)$")
      name = name or arg
      assert(
        name == "--repo"
          or name == "-C"
          or name == "--exclude"
          or name == "--selected-file"
          or name == "--untracked"
          or name == "--file"
          or name == "--pr"
          or name == "--layout"
          or name == "--explorer-position",
        "diffreel: unknown option " .. name
      )
      if value == nil then
        i = i + 1
        value = args[i]
      end
      assert(value ~= nil and value ~= "", "diffreel: missing value for " .. name)
      if name == "--layout" then
        result.layout = value
      elseif name == "--pr" then
        result.pr = value
      elseif name == "--file" then
        result.file = value
      elseif name == "--explorer-position" then
        result.explorer = result.explorer or {}
        result.explorer.position = value
      elseif name == "--untracked" then
        assert(value == "all" or value == "no", "diffreel: --untracked expects all or no")
        result.untracked = value == "all"
      elseif name == "--exclude" then
        result.exclude = result.exclude or {}
        result.exclude[#result.exclude + 1] = value
      else
        result[name == "--selected-file" and "selected_file" or "root"] = value
      end
    else
      revisions[#revisions + 1] = arg
    end
    i = i + 1
  end
  assert(
    #revisions <= 2,
    "diffreel: usage: Diffreel [options] [left revision] [right revision|worktree] [-- pathspec ...]"
  )
  result.left, result.right = revisions[1], revisions[2]
  if mode == "staged" then
    assert(#revisions <= 1, "diffreel: --staged accepts at most one baseline revision")
    result.left, result.right = revisions[1] or "HEAD", ":0"
  elseif mode == "unstaged" then
    assert(#revisions == 0, "diffreel: --unstaged does not accept revisions")
    result.left, result.right = ":0", "worktree"
  end
  M.validate(result)
  return result
end

function M.preferred_path(root, current, selected)
  if selected == false then
    return nil
  end
  local path = selected or current
  if not path or path == "" then
    return nil
  end
  root = vim.fs.normalize(root):gsub("/$", "")
  path = vim.fs.normalize(path:sub(1, 1) == "/" and path or root .. "/" .. path)
  local prefix = root .. "/"
  if path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
end

return M
