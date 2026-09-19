local M = {}
local presentation = require("diffreel.presentation")
local layout = require("diffreel.layout")
local windows = require("diffreel.windows")
local options = require("diffreel.options")
local directions = { left = "left", right = "right", top = "above", bottom = "below" }
local resize_generation = 0

function M.visible(view)
  local win = view.explorer_win
  return win ~= nil and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == view.tab
end

function M.windows(view)
  return windows.owned_windows(view)
end

local function vertical(position)
  return position == "left" or position == "right"
end

function M.resized()
  resize_generation = resize_generation + 1
end

function M.axis(settings)
  return vertical(settings.position) and "width" or "height"
end

local function source(view, settings, axis)
  if axis == "width" and settings.width == nil then
    return view.default_explorer_width
  end
  return settings[axis]
end

function M.pending(view)
  local axis = M.axis(view.explorer_options)
  local value = source(view, view.explorer_options, axis)
  return (value == nil or type(value) == "function") and (view.explorer_generations or {})[axis] ~= resize_generation,
    resize_generation
end

function M.prepare(view, settings, patch, automatic)
  if not settings.visible or (automatic and not M.pending(view)) then
    return
  end
  local axis = M.axis(settings)
  local shown = M.visible(view)
  local saved = (view.explorer_sizes or {})[axis]
  if shown and axis == M.axis(view.explorer_options) then
    saved = axis == "width" and vim.api.nvim_win_get_width(view.explorer_win)
      or vim.api.nvim_win_get_height(view.explorer_win)
  end
  local value = source(view, settings, axis)
  local dynamic = value == nil or type(value) == "function"
  local evaluate = patch[axis] ~= nil
    or settings.position ~= view.explorer_options.position
    or (not shown and saved == nil)
    or (dynamic and (automatic or (not shown and M.pending(view))))
  if shown and not evaluate then
    return
  end
  local generation = resize_generation
  if not evaluate or not dynamic then
    value = patch[axis] or saved or value
  end
  if type(value) == "function" then
    value = value({ columns = vim.o.columns, lines = vim.o.lines })
    options.dimension(value, axis)
  elseif value == nil then
    value = math.min(35, math.max(22, math.floor(vim.o.columns * 0.2)))
  end
  local limit = axis == "width" and vim.o.columns - 6 or math.floor(vim.o.lines / 2)
  return { axis = axis, size = math.min(value, math.max(1, limit)), generation = generation, automatic = automatic }
end

local function style(win, position)
  vim.api.nvim_win_call(win, function()
    -- A split of a diff window can register the Explorer as a third diff buffer.
    vim.cmd("diffoff")
  end)
  for name, value in pairs({
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    foldenable = false,
    foldcolumn = "0",
    cursorline = true,
    winfixwidth = vertical(position),
    winfixheight = not vertical(position),
  }) do
    vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
  end
end

function M.apply(view, settings, patch, sizing)
  patch = patch or {}
  local old, old_win = view.explorer_options, view.explorer_win
  local shown = M.visible(view)
  local focused = vim.api.nvim_get_current_win() == old_win
  local fraction = layout.ratio(view)
  local sizes = view.explorer_sizes or {}
  view.explorer_sizes = sizes
  if shown then
    local axis = vertical(old.position) and "width" or "height"
    sizes[axis] = axis == "width" and vim.api.nvim_win_get_width(old_win) or vim.api.nvim_win_get_height(old_win)
    view.explorer_saved = vim.api.nvim_win_call(old_win, vim.fn.winsaveview)
  end
  local function rebalance()
    if view.alive and vim.api.nvim_win_is_valid(view.left_win) and vim.api.nvim_win_is_valid(view.right_win) then
      layout.balance(view, fraction)
    end
  end
  local created
  view.layout_changing = true
  local ok, err = xpcall(function()
    if not settings.visible then
      view.explorer_win, view.explorer_options = nil, settings
      if shown then
        vim.api.nvim_win_call(old_win, function()
          vim.cmd("diffoff")
        end)
        vim.api.nvim_win_close(old_win, true)
        presentation.restore(view, old_win)
      end
      rebalance()
      return
    end
    local moved = not shown or old.position ~= settings.position
    vim.api.nvim_win_call(view.right_win, function()
      if not shown then
        created = vim.api.nvim_open_win(
          view.explorer_buf,
          false,
          { split = directions[settings.position], win = -view.right_win }
        )
        view.explorer_win = created
        vim.wo[created].winbar = ""
      elseif moved then
        vim.api.nvim_win_set_config(old_win, { split = directions[settings.position], win = -view.right_win })
      end
    end)
    local win = view.explorer_win
    if not sizing or not sizing.automatic then
      style(win, settings.position)
      presentation.chrome(view, win, "Explorer")
    end
    if sizing then
      local measure = sizing.axis == "width" and vim.api.nvim_win_get_width or vim.api.nvim_win_get_height
      local resize = sizing.axis == "width" and vim.api.nvim_win_set_width or vim.api.nvim_win_set_height
      if measure(win) ~= sizing.size then
        resize(win, sizing.size)
      end
    end
    if view.explorer_saved then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view.explorer_saved)
      end)
    end
    view.explorer_options = settings
    rebalance()
  end, debug.traceback)
  view.layout_changing = false
  if not ok then
    if created and vim.api.nvim_win_is_valid(created) then
      pcall(vim.api.nvim_win_close, created, true)
    end
    view.explorer_win = old_win and vim.api.nvim_win_is_valid(old_win) and old_win or nil
    view.explorer_options = vim.tbl_extend("force", old, { visible = view.explorer_win ~= nil })
    if M.visible(view) then
      pcall(vim.api.nvim_win_call, view.right_win, function()
        vim.api.nvim_win_set_config(old_win, { split = directions[old.position], win = -view.right_win })
        style(old_win, old.position)
        rebalance()
      end)
    end
  end
  if focused and not M.visible(view) and vim.api.nvim_win_is_valid(view.right_win) then
    vim.api.nvim_set_current_win(view.right_win)
  end
  if not ok then
    error(err, 0)
  end
  for _, axis in ipairs({ "width", "height" }) do
    if patch[axis] ~= nil then
      sizes[axis] = nil
      if view.explorer_generations then
        view.explorer_generations[axis] = nil
      end
    end
  end
  if sizing then
    view.explorer_generations = view.explorer_generations or {}
    view.explorer_generations[sizing.axis] = sizing.generation
    if view.explorer_size_errors then
      view.explorer_size_errors[sizing.axis] = nil
    end
  end
end

return M
