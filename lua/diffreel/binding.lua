local lifetime = require("diffreel.lifetime")
local M = {}
local idle = vim.keycode("<Ignore>")

-- Native scrollbind moves the peers only when a Normal command ends with the window's view differing from
-- the one it last recorded, which API cursor moves and nested motions leave stale. Recording a shifted view
-- first makes the second command propagate the real one with the native diff alignment.
function M.align(win)
  if not vim.wo[win].scrollbind then
    return
  end
  vim.api.nvim_win_call(win, function()
    local saved = vim.fn.winsaveview()
    local shifted = saved.topline > 1 and 1 or vim.api.nvim_buf_line_count(0)
    -- Leaving the cursor behind lets the command scroll back to it and record the unshifted view.
    vim.fn.winrestview({ topline = shifted, lnum = shifted })
    vim.cmd("normal! " .. idle)
    vim.fn.winrestview(saved)
    vim.cmd("normal! " .. idle)
  end)
end

local function position(win)
  local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  return { view.topline, view.topfill, view.leftcol }
end

-- Native cursorbind puts the peer's cursor on the matching line, and a peer whose line is shorter scrolls
-- back to that cursor after scrollbind has copied the column offset. The peer can end where it started, so
-- its own scroll event is not a reliable sign.
local function level(view, current)
  local peer = current == view.left_win and view.right_win or view.left_win
  if not vim.wo[peer].scrollbind or not vim.wo[current].scrollbind then
    return
  end
  local leftcol = vim.api.nvim_win_call(current, vim.fn.winsaveview).leftcol
  if vim.api.nvim_win_call(peer, vim.fn.winsaveview).leftcol ~= leftcol then
    vim.api.nvim_win_call(peer, function()
      vim.fn.winrestview({ leftcol = leftcol })
    end)
    view.aligned = { win = peer, position = position(peer) }
  end
end

-- Native scrollbind follows only the current window, so a pane scrolled by the mouse while another window
-- has focus leaves its peer behind. A pane whose view moved for another reason, such as replaced content,
-- must not drag the pane the user is reading.
function M.follow(view, scrolled)
  local echo = view.aligned
  view.aligned = nil
  -- The realigned peer reports its own scroll in a later event, possibly together with the next scroll of
  -- the source; following it back can shift the source across filler.
  local function moved(win)
    return scrolled[tostring(win)] ~= nil
      and not (echo and echo.win == win and vim.deep_equal(echo.position, position(win)))
  end
  local left, right = moved(view.left_win), moved(view.right_win)
  local current = vim.api.nvim_get_current_win()
  if (left and current == view.left_win) or (right and current == view.right_win) then
    level(view, current)
  end
  if left == right then
    return
  end
  local source, peer = view.left_win, view.right_win
  if right then
    source, peer = peer, source
  end
  if vim.fn.getmousepos().winid ~= source then
    return
  end
  local waiting = view.following
  view.following = { source = source, peer = peer }
  if waiting then
    return
  end
  -- A Normal command run from WinScrolled discards the next queued input event, which halves a burst of
  -- wheel scrolling; scheduled callbacks wait until the queue is empty.
  vim.schedule(function()
    local target = view.following
    view.following = nil
    if
      not lifetime.valid(view)
      or view.layout == "inline"
      or view.layout_changing
      or target.source == vim.api.nvim_get_current_win()
      or vim.fn.mode():sub(1, 1) == "c"
    then
      return
    end
    local before = position(target.peer)
    M.align(target.source)
    local after = position(target.peer)
    if not vim.deep_equal(before, after) then
      view.aligned = { win = target.peer, position = after }
    end
  end)
end

return M
