local M = {}
local lease = require("diffreel.lease")
local owners = setmetatable({}, { __mode = "k" })
local native_options = { "foldcolumn", "foldmethod", "foldenable", "wrap", "scrollbind", "cursorbind" }

function M.capture_window(win)
  local options = {}
  for _, name in ipairs({
    "winhighlight",
    "winbar",
    "fillchars",
    "number",
    "relativenumber",
    "wrap",
    "scrollbind",
    "cursorbind",
    "signcolumn",
    "cursorline",
    "foldcolumn",
    "foldtext",
    "foldmethod",
    "foldenable",
    "foldlevel",
    "foldexpr",
    "numberwidth",
  }) do
    options[name] = vim.api.nvim_get_option_value(name, { win = win, scope = name == "fillchars" and "local" or nil })
  end
  return options
end

function M.restore_window(win, options)
  for name, value in pairs(options) do
    vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
end

local function option(view, win, name, value, reset)
  view.presentation = view.presentation or {}
  view.presentation[win] = view.presentation[win] or {}
  local buf = vim.api.nvim_win_get_buf(win)
  view.presentation[win][buf] = view.presentation[win][buf] or {}
  local options = view.presentation[win][buf]
  local current = vim.api.nvim_get_option_value(name, { win = win })
  if not options[name] then
    local original = name == "fillchars" and vim.api.nvim_get_option_value(name, { win = win, scope = "local" })
      or current
    for other in pairs(owners) do
      for _, buffers in pairs(other.presentation or {}) do
        local state = buffers[buf] and buffers[buf][name]
        if state and state.installed == current then
          original = state.original
        end
      end
    end
    options[name] = { original = original }
  elseif current ~= options[name].installed and not reset then
    return
  end
  vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  options[name].installed = vim.api.nvim_get_option_value(name, { win = win })
  owners[view] = true
end

local function remap(existing, replacements)
  local parts = {}
  for from, to in existing:gmatch("([^,:]+):([^,]+)") do
    if not replacements[from] then
      parts[#parts + 1] = from .. ":" .. to
    end
  end
  for _, from in ipairs(vim.tbl_keys(replacements)) do
    parts[#parts + 1] = from .. ":" .. replacements[from]
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

function M.chrome(view, win, scope)
  local replacements = {}
  for _, name in ipairs({ "Normal", "NormalNC", "WinSeparator", "WinBar", "WinBarNC" }) do
    replacements[name] = "Diffreel" .. scope .. name
  end
  for _, name in ipairs(scope == "Explorer" and { "CursorLine" } or { "LineNr", "CursorLineNr", "FoldColumn" }) do
    replacements[name] = "Diffreel" .. scope .. name
  end
  for from, to in vim.wo[win].winhighlight:gmatch("([^,:]+):([^,]+)") do
    if to ~= "DiffreelDiff" .. from and to ~= "DiffreelExplorer" .. from then
      replacements[from] = nil
    end
  end
  option(view, win, "winhighlight", remap(vim.wo[win].winhighlight, replacements))
  -- Parsing fillchars through vim.opt loses literal commas used as fill characters.
  local fills, quiet = vim.wo[win].fillchars, scope == "Diff" and "eob: ,diff: " or "eob: "
  if fills:sub(-#quiet) ~= quiet then
    fills = fills .. (fills == "" and "" or ",") .. quiet
  end
  option(view, win, "fillchars", fills)
end

function M.diffthis(view, win)
  -- Capturing after diffthis mistakes native diff's temporary values for ordinary window settings.
  for _, name in ipairs(native_options) do
    option(view, win, name, vim.api.nvim_get_option_value(name, { win = win }), true)
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd.diffthis()
  end)
  local options = view.presentation[win][vim.api.nvim_win_get_buf(win)]
  for _, name in ipairs(native_options) do
    options[name].installed = vim.api.nvim_get_option_value(name, { win = win })
  end
end

local function stop_diff(win, options)
  if not vim.wo[win].diff then
    return
  end
  local before = {}
  for _, name in ipairs(native_options) do
    if options and options[name] then
      before[name] = vim.api.nvim_get_option_value(name, { win = win })
    end
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd.diffoff()
  end)
  for name, value in pairs(before) do
    local state = options[name]
    if state.installed == value then
      -- Native diffoff also disables manual folds, so its writes still belong to this lease.
      state.installed = vim.api.nvim_get_option_value(name, { win = win })
    else
      vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
    end
  end
end

function M.diffoff(view, win)
  local buffers = view.presentation and view.presentation[win]
  stop_diff(win, buffers and buffers[vim.api.nvim_win_get_buf(win)])
end

function M.apply(view, win, restarted)
  local old = win == view.left_win
  local line, text =
    old and "DiffreelLineDelete" or "DiffreelLineAdd", old and "DiffreelTextDelete" or "DiffreelTextAdd"
  option(
    view,
    win,
    "winhighlight",
    remap(vim.wo[win].winhighlight, {
      DiffAdd = line,
      DiffChange = line,
      DiffText = text,
      DiffTextAdd = text,
      DiffDelete = "DiffreelFiller",
      Folded = "DiffreelDiffFolded",
    })
  )
  M.chrome(view, win, "Diff")
  option(view, win, "foldcolumn", "1", restarted)
  option(view, win, "number", true)
  option(view, win, "relativenumber", false)
  option(view, win, "signcolumn", "no")
  option(view, win, "wrap", false)
  option(view, win, "foldtext", "'  ⋯ ' . (v:foldend - v:foldstart + 1) . ' unchanged lines ⋯'")
  option(view, win, "cursorline", false)
end

function M.header(view, win, value)
  option(view, win, "winbar", value)
end

function M.engine(view, win)
  for name, value in pairs({
    foldenable = false,
    wrap = false,
    scrollbind = false,
    cursorbind = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldcolumn = "0",
  }) do
    option(view, win, name, value)
  end
end

function M.inline(view, win)
  M.apply(view, win)
  option(view, win, "foldexpr", "v:lua.require'diffreel.inline'.fold(v:lnum)")
  option(view, win, "foldmethod", "expr", true)
  option(view, win, "foldenable", true, true)
  option(
    view,
    win,
    "numberwidth",
    math.max(vim.wo[win].numberwidth, #tostring(vim.api.nvim_buf_line_count(view.left_buf)) + 1)
  )
end

function M.restore(view, win)
  local buffers = view.presentation and view.presentation[win]
  if not buffers then
    return
  end
  if not vim.api.nvim_win_is_valid(win) then
    view.presentation[win] = nil
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local options = buffers[buf]
  if not options then
    return
  end
  for name, state in pairs(options) do
    if vim.api.nvim_get_option_value(name, { win = win }) == state.installed then
      vim.api.nvim_set_option_value(name, state.original, { win = win, scope = "local" })
    end
  end
  buffers[buf] = nil
  if not next(buffers) then
    view.presentation[win] = nil
  end
end

local function clean_copies(view, outside)
  for original_win, buffers in pairs(view.presentation or {}) do
    for buf, options in pairs(buffers) do
      for _, win in ipairs(vim.fn.win_findbuf(buf)) do
        local owned = win == original_win
        for other in pairs(owners) do
          if vim.tbl_contains(require("diffreel.layout").owned_windows(other), win) then
            owned = true
          end
        end
        local highlight = options.winhighlight
        if
          not owned
          and (not outside or vim.api.nvim_win_get_tabpage(win) ~= view.tab)
          and highlight
          and vim.wo[win].winhighlight == highlight.installed
        then
          local copied = vim.deepcopy(options)
          stop_diff(win, copied)
          for name, state in pairs(copied) do
            if vim.api.nvim_get_option_value(name, { win = win }) == state.installed then
              vim.api.nvim_set_option_value(name, state.original, { win = win, scope = "local" })
            end
          end
        end
      end
    end
  end
end

function M.clean_copies()
  for view in pairs(owners) do
    clean_copies(view, true)
  end
end

function M.dispose(view)
  owners[view] = nil
  local errors = {}
  local function attempt(action)
    local ok, err = pcall(action)
    if not ok then
      errors[#errors + 1] = tostring(err)
    end
  end
  attempt(function()
    clean_copies(view, false)
  end)
  for _, buffers in pairs(view.presentation or {}) do
    for buf, options in pairs(buffers) do
      if
        vim.api.nvim_buf_is_valid(buf)
        and vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].buftype == ""
        and #vim.fn.win_findbuf(buf) == 0
      then
        -- Restoring only visible windows leaves hidden buffers' cached window options behind.
        attempt(function()
          lease.preserve_buffer(buf, function()
            local hidden = vim.bo[buf].bufhidden
            local ignored = vim.o.eventignore
            local quiet = "BufEnter,BufLeave,BufWinEnter,BufWinLeave,WinEnter,WinLeave,WinClosed,OptionSet"
            local win, scratch
            attempt(function()
              vim.o.eventignore = ignored == "" and quiet or (ignored .. "," .. quiet)
              vim.bo[buf].bufhidden = "hide"
              local initial = view.empty_buf
              if not vim.api.nvim_buf_is_valid(initial) then
                scratch = vim.api.nvim_create_buf(false, true)
                initial = scratch
              end
              win = vim.api.nvim_open_win(
                initial,
                false,
                { relative = "editor", row = 0, col = 0, width = 2, height = 2, hide = true, noautocmd = true }
              )
              -- Opening the source directly can fail before the new window ID is returned.
              vim.api.nvim_win_set_buf(win, buf)
            end)
            if win and vim.api.nvim_win_is_valid(win) then
              if vim.api.nvim_win_get_buf(win) == buf then
                for name, state in pairs(options) do
                  attempt(function()
                    local current = vim.api.nvim_get_option_value(name, { win = win })
                    if current == state.installed or current == state.original then
                      vim.api.nvim_set_option_value(name, state.original, { win = win, scope = "local" })
                    end
                  end)
                end
              end
              attempt(function()
                vim.api.nvim_win_close(win, true)
              end)
            end
            if scratch and vim.api.nvim_buf_is_valid(scratch) then
              attempt(function()
                vim.api.nvim_buf_delete(scratch, { force = true })
              end)
            end
            attempt(function()
              if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].bufhidden == "hide" then
                vim.bo[buf].bufhidden = hidden
              end
            end)
            vim.o.eventignore = ignored
          end)
        end)
      end
    end
  end
  if #errors > 0 then
    error(table.concat(errors, "\n"), 0)
  end
end

return M
