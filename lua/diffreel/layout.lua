local M = {}

local function dimensions(view)
  local getter = view.layout == "stacked" and vim.api.nvim_win_get_height or vim.api.nvim_win_get_width
  return getter(view.left_win), getter(view.right_win)
end

function M.capture_ratio(view)
  if view.layout == "inline" or view.layout_resize_pending then
    return
  end
  local left, right = dimensions(view)
  local previous = view.layout_size
  if not previous or previous.mode ~= view.layout or previous.left ~= left or previous.right ~= right then
    view.layout_ratios = view.layout_ratios or {}
    view.layout_ratios[view.layout] = left / (left + right)
    view.layout_size = { mode = view.layout, left = left, right = right }
  end
end

function M.ratio(view)
  M.capture_ratio(view)
  return (view.layout_ratios or {})[view.layout] or 0.5
end

function M.balance(view, ratio)
  if view.layout == "inline" or not view.alive then
    return
  end
  local left, right = dimensions(view)
  local target = math.max(1, math.min(left + right - 1, math.floor((left + right) * ratio + 0.5)))
  if left ~= target then
    local setter = view.layout == "stacked" and vim.api.nvim_win_set_height or vim.api.nvim_win_set_width
    setter(view.left_win, target)
  end
  if not view.alive then
    return
  end
  left, right = dimensions(view)
  view.layout_ratios = view.layout_ratios or {}
  view.layout_ratios[view.layout] = ratio
  -- Recording rounded or constrained geometry as a new preference would drift on every resize.
  view.layout_size = { mode = view.layout, left = left, right = right }
end

function M.resize(view)
  M.balance(view, (view.layout_ratios or {})[view.layout] or 0.5)
  view.layout_resize_pending = nil
end

function M.visible_windows(view)
  local wins = { view.right_win }
  if view.layout ~= "inline" then
    table.insert(wins, 1, view.left_win)
  end
  return wins
end

function M.engine_windows(view)
  return { view.left_win, view.right_engine or view.right_win }
end

function M.owned_windows(view)
  local wins, seen = {}, {}
  local function add(win)
    if win and not seen[win] then
      wins[#wins + 1], seen[win] = win, true
    end
  end
  add(view.left_win)
  add(view.right_win)
  add(view.right_engine)
  add(view.explorer_win)
  for _, win in ipairs(view.layout_staging or {}) do
    add(win)
  end
  return wins
end

function M.visible_pane(view, win)
  return win == view.right_win or (win == view.left_win and view.layout ~= "inline") or win == view.explorer_win
end

function M.engine(view, win)
  return win == view.right_win and (view.right_engine or win) or win
end

local function hidden(buf, source)
  return vim.api.nvim_win_call(source, function()
    return vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 2,
      height = 10,
      hide = true,
      focusable = false,
      noautocmd = true,
    })
  end)
end

local function engine_options(view, win)
  require("diffreel.presentation").engine(view, win)
end

function M.staging(view)
  local wins = {}
  view.layout_staging = wins
  local ok, err = pcall(function()
    for _, buf in ipairs({ view.left_buf, view.right_buf }) do
      wins[#wins + 1] = hidden(buf, view.right_win)
      require("diffreel.presentation").diffthis(view, wins[#wins])
      engine_options(view, wins[#wins])
    end
  end)
  if not ok then
    M.clear_staging(view)
    error(err, 0)
  end
  return wins
end

local function close_engine(view, win)
  if win and vim.api.nvim_win_is_valid(win) then
    local failure
    local function attempt(action)
      local ok, err = pcall(action)
      if not ok then
        failure = failure or err
      end
    end
    attempt(function()
      vim.api.nvim_win_call(win, function()
        require("diffreel.presentation").diffoff(view, win)
      end)
    end)
    attempt(function()
      require("diffreel.presentation").restore(view, win)
    end)
    attempt(function()
      vim.api.nvim_win_close(win, true)
    end)
    if failure then
      error(failure, 0)
    end
  end
end

function M.clear_staging(view)
  local wins = view.layout_staging or {}
  view.layout_staging = nil
  for _, win in ipairs(wins) do
    pcall(close_engine, view, win)
  end
end

function M.apply(view, mode)
  local presentation = require("diffreel.presentation")
  local previous, right = view.layout or "side_by_side", view.right_win
  if mode == previous then
    return
  end
  local cursor = vim.api.nvim_win_call(right, vim.fn.winsaveview)
  local focused = vim.api.nvim_get_current_win() == view.left_win
  view.layout_ratios = view.layout_ratios or {}
  if previous ~= "inline" then
    require("diffreel.inline").capture_folds(view)
    M.capture_ratio(view)
    view.saved_left_view = vim.api.nvim_win_call(view.left_win, vim.fn.winsaveview)
  end
  local old_engine, created = view.right_engine, nil
  local previous_diff = {}
  for _, win in ipairs(M.engine_windows(view)) do
    previous_diff[win] = vim.wo[win].diff
  end
  view.layout_changing = true
  local ok, err = xpcall(function()
    if mode == "inline" then
      created = view.layout_staging and view.layout_staging[2] or hidden(view.right_buf, right)
      if view.layout_staging then
        view.layout_staging[2] = nil
      end
      view.right_engine = created
      vim.api.nvim_win_set_config(
        view.left_win,
        { relative = "editor", row = 0, col = 0, width = 2, height = 10, hide = true, focusable = false }
      )
      for _, win in ipairs(M.engine_windows(view)) do
        if vim.wo[right].diff and not vim.wo[win].diff then
          vim.api.nvim_win_call(win, function()
            presentation.diffthis(view, win)
          end)
        end
        engine_options(view, win)
      end
      vim.api.nvim_win_call(right, function()
        presentation.diffoff(view, right)
      end)
      presentation.restore(view, right)
      view.layout = mode
      presentation.inline(view, right)
    else
      if previous == "inline" then
        require("diffreel.inline").clear(view)
        presentation.restore(view, right)
      end
      vim.api.nvim_win_set_config(
        view.left_win,
        { split = mode == "stacked" and "above" or "left", win = right, hide = false, focusable = true }
      )
      if previous == "inline" then
        local active = vim.wo[view.left_win].diff
        vim.api.nvim_win_call(view.left_win, function()
          presentation.diffoff(view, view.left_win)
        end)
        presentation.restore(view, view.left_win)
        if active then
          presentation.diffthis(view, view.left_win)
        end
      end
      view.layout = mode
      if old_engine and vim.wo[old_engine].diff then
        presentation.diffthis(view, right)
      end
      for _, win in ipairs(M.visible_windows(view)) do
        if vim.wo[win].diff then
          presentation.apply(view, win, previous == "inline")
        end
      end
      M.balance(view, view.layout_ratios[mode] or 0.5)
      if previous == "inline" and view.saved_left_view then
        vim.api.nvim_win_call(view.left_win, function()
          vim.fn.winrestview(view.saved_left_view)
        end)
      end
      view.last_split = mode
      require("diffreel.inline").restore_folds(view)
    end
  end, debug.traceback)
  if not ok then
    view.layout, view.right_engine = previous, old_engine
    if created and created ~= old_engine then
      pcall(close_engine, view, created)
    end
    if previous ~= "inline" then
      pcall(
        vim.api.nvim_win_set_config,
        view.left_win,
        { split = previous == "stacked" and "above" or "left", win = right, hide = false, focusable = true }
      )
      for _, win in ipairs(M.visible_windows(view)) do
        pcall(vim.api.nvim_win_call, win, function()
          if previous_diff[win] then
            presentation.diffthis(view, win)
            presentation.apply(view, win, true)
          else
            presentation.diffoff(view, win)
            presentation.restore(view, win)
          end
        end)
      end
    elseif old_engine and vim.api.nvim_win_is_valid(old_engine) then
      pcall(
        vim.api.nvim_win_set_config,
        view.left_win,
        { relative = "editor", row = 0, col = 0, width = 2, height = 10, hide = true, focusable = false }
      )
      for _, win in ipairs(M.engine_windows(view)) do
        pcall(vim.api.nvim_win_call, win, function()
          if previous_diff[win] and not vim.wo[win].diff then
            presentation.diffthis(view, win)
          end
          engine_options(view, win)
        end)
      end
      pcall(vim.api.nvim_win_call, right, function()
        presentation.restore(view, right)
        presentation.diffoff(view, right)
        presentation.inline(view, right)
      end)
    end
  end
  if ok and mode ~= "inline" then
    view.right_engine = nil
    local closed, warning = pcall(close_engine, view, old_engine)
    if not closed then
      vim.notify(
        "diffreel: layout applied with a cleanup warning: " .. tostring(warning):match("[^\n]+"),
        vim.log.levels.WARN
      )
    end
  end
  M.clear_staging(view)
  view.layout_changing = false
  if vim.api.nvim_win_is_valid(right) then
    vim.api.nvim_win_call(right, function()
      vim.fn.winrestview(cursor)
    end)
    if focused and mode == "inline" then
      vim.api.nvim_set_current_win(right)
    end
  end
  if not ok then
    error(err, 0)
  end
end

function M.dispose(view)
  M.clear_staging(view)
  local right = view.right_engine
  view.right_engine = nil
  pcall(close_engine, view, right)
  if view.layout == "inline" then
    pcall(close_engine, view, view.left_win)
  end
end

return M
