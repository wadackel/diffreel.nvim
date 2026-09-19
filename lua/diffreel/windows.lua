local M = {}

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

return M
