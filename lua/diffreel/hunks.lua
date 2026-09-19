local M = {}
local windows = require("diffreel.windows")
local inline = require("diffreel.inline")
local phase = require("diffreel.phase")

local function prepared(view, win)
  if not view.alive or not phase.interactive(view) then
    return false
  end
  if win ~= view.left_win and win ~= view.right_win then
    return false
  end
  for _, side in ipairs({ "left", "right" }) do
    local pane, buf = windows.engine(view, view[side .. "_win"]), view[side .. "_buf"]
    if not vim.api.nvim_win_is_valid(pane) or vim.api.nvim_win_get_buf(pane) ~= buf or not vim.wo[pane].diff then
      return false
    end
  end
  return true
end

local function query(view, action)
  local positions = {}
  for _, win in ipairs(windows.engine_windows(view)) do
    positions[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end
  local ok, result = pcall(action)
  -- Native motions also move the peer through cursorbind and scrollbind.
  for win, position in pairs(positions) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(position)
      end)
    end
  end
  if not ok then
    error(result, 0)
  end
  return result
end

local function motion(direction, count)
  vim.cmd("keepjumps normal! " .. (count or 1) .. (direction > 0 and "]c" or "[c"))
  return vim.api.nvim_win_get_cursor(0)[1]
end

local function edge(last)
  local length = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { last and 1 or length, 0 })
  return motion(last and 1 or -1, length + 1)
end

function M.place(view, win, row)
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  if view.layout == "inline" and win == view.right_win then
    inline.reveal_start(view)
  end
end

function M.boundary(view, win, last)
  if not prepared(view, win) then
    return
  end
  win = windows.engine(view, win)
  return query(view, function()
    local found = false
    for _, pane in ipairs({ win, win == view.left_win and (view.right_engine or view.right_win) or view.left_win }) do
      vim.api.nvim_win_call(pane, function()
        local row = edge(last)
        found = found or vim.fn.diff_hlID(row, 1) > 0 or vim.fn.diff_filler(row) > 0 or vim.fn.diff_filler(row + 1) > 0
      end)
    end
    if found then
      return vim.api.nvim_win_call(win, function()
        return edge(last)
      end)
    end
  end)
end

function M.move(view, win, direction)
  if not prepared(view, win) then
    return false
  end
  local engine = windows.engine(view, win)
  if engine ~= win then
    local before = vim.api.nvim_win_get_cursor(win)
    local row = query(view, function()
      return vim.api.nvim_win_call(engine, function()
        vim.api.nvim_win_set_cursor(engine, before)
        return motion(direction)
      end)
    end)
    if row ~= before[1] then
      M.place(view, win, row)
      return true
    end
    return false
  end
  return vim.api.nvim_win_call(win, function()
    local before = vim.api.nvim_win_get_cursor(0)[1]
    return motion(direction) ~= before
  end)
end

function M.eligible(view, win)
  if not prepared(view, win) then
    return false
  end
  local side = win == view.left_win and "left" or "right"
  local buf = view[side .. "_buf"]
  local entry = view.by_path[view.selected_path]
  local metadata = entry and entry[side]
  if not metadata or metadata.kind == "limited" then
    return false
  end
  local draft = side == "right" and buf ~= view.empty_buf and vim.bo[buf].modified
  if not draft and (metadata.kind == "missing" or metadata.size == 0) then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  return vim.api.nvim_win_call(windows.engine(view, win), function()
    return vim.fn.diff_hlID(row, 1) > 0
  end)
end

function M.range(view, win, count)
  if not M.eligible(view, win) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(win)
  win = windows.engine(view, win)
  return query(view, function()
    return vim.api.nvim_win_call(win, function()
      vim.api.nvim_win_set_cursor(win, cursor)
      local row, length = vim.api.nvim_win_get_cursor(0)[1], vim.api.nvim_buf_line_count(0)
      local first = row
      if row > 1 then
        vim.api.nvim_win_set_cursor(0, { row - 1, 0 })
        if motion(1) ~= row then
          vim.api.nvim_win_set_cursor(0, { row, 0 })
          first = motion(-1)
        end
      end
      local start, finish, remaining = first, first, count or 1
      while remaining > 0 do
        vim.api.nvim_win_set_cursor(0, { start, 0 })
        local next_start = motion(1)
        local limit = next_start > start and next_start - 1 or length
        local last = start - 1
        while last < limit and vim.fn.diff_hlID(last + 1, 1) > 0 do
          last = last + 1
        end
        if last >= start then
          finish, remaining = last, remaining - 1
        end
        if next_start <= start then
          break
        end
        start = next_start
      end
      return { first, finish }
    end)
  end)
end

function M.select(view, win, count)
  local range = M.range(view, win, count)
  if not range then
    return
  end
  vim.api.nvim_win_call(win, function()
    vim.cmd("normal! " .. vim.keycode("<Esc>"))
    vim.api.nvim_win_set_cursor(0, { range[1], 0 })
    vim.cmd("normal! V")
    -- selectmode=cmd makes V enter Select mode, which changes operator line semantics.
    if vim.fn.mode() == "S" then
      vim.cmd("normal! " .. vim.keycode("<C-G>"))
    end
    vim.api.nvim_win_set_cursor(0, { range[2], 0 })
  end)
end

return M
