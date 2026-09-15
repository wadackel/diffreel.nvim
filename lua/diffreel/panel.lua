local M = {}
local presentation = require("diffreel.presentation")
local directions = { left = "left", right = "right", top = "above", bottom = "below" }

function M.visible(view)
  local win = view.explorer_win
  return win ~= nil and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == view.tab
end

function M.windows(view)
  return require("diffreel.layout").owned_windows(view)
end

local function vertical(position)
  return position == "left" or position == "right"
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

function M.apply(view, settings, patch)
  patch = patch or {}
  local old, old_win = view.explorer_options, view.explorer_win
  local shown = M.visible(view)
  local focused = vim.api.nvim_get_current_win() == old_win
  local left_width, right_width = vim.api.nvim_win_get_width(view.left_win), vim.api.nvim_win_get_width(view.right_win)
  local fraction = left_width / (left_width + right_width)
  local sizes = view.explorer_sizes or {}
  view.explorer_sizes = sizes
  if shown then
    local axis = vertical(old.position) and "width" or "height"
    sizes[axis] = axis == "width" and vim.api.nvim_win_get_width(old_win) or vim.api.nvim_win_get_height(old_win)
    view.explorer_saved = vim.api.nvim_win_call(old_win, vim.fn.winsaveview)
  end
  local function rebalance()
    if view.layout == "inline" or view.layout == "stacked" then
      return
    end
    if view.alive and vim.api.nvim_win_is_valid(view.left_win) and vim.api.nvim_win_is_valid(view.right_win) then
      -- Moving a split can give all recovered width to one neighbor and distort a balanced diff.
      local width = vim.api.nvim_win_get_width(view.left_win) + vim.api.nvim_win_get_width(view.right_win)
      local target = math.max(1, math.min(width - 1, math.floor(width * fraction + 0.5)))
      if vim.api.nvim_win_get_width(view.left_win) ~= target then
        vim.api.nvim_win_set_width(view.left_win, target)
      end
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
    local moved = not shown or old.position ~= settings.position or patch.position ~= nil
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
    style(win, settings.position)
    presentation.chrome(view, win, "Explorer")
    if moved or patch.width ~= nil or patch.height ~= nil then
      if vertical(settings.position) then
        local width = patch.width or sizes.width or settings.width or view.default_explorer_width
        vim.api.nvim_win_set_width(win, math.min(width, math.max(1, vim.o.columns - 6)))
      else
        local height = patch.height or sizes.height or settings.height
        vim.api.nvim_win_set_height(win, math.min(height, math.max(1, math.floor(vim.o.lines / 2))))
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
end

return M
