local windows = require("diffreel.windows")
local M = {}

function M.valid(view)
  if not view.alive or not vim.api.nvim_tabpage_is_valid(view.tab) then
    return false
  end
  for _, win in ipairs(windows.owned_windows(view)) do
    if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_tabpage(win) ~= view.tab then
      return false
    end
  end
  if not view.layout_changing then
    if not view.explorer_options or view.explorer_options.visible then
      if not windows.explorer_visible(view) or vim.api.nvim_win_get_buf(view.explorer_win) ~= view.explorer_buf then
        return false
      end
    elseif view.explorer_win ~= nil then
      return false
    end
  end
  return vim.api.nvim_buf_is_valid(view.explorer_buf)
    and vim.api.nvim_buf_is_valid(view.left_buf)
    and vim.api.nvim_buf_is_valid(view.empty_buf)
    and vim.api.nvim_win_get_buf(view.left_win) == view.left_buf
end

local scopes = { manager = true, comparison = true, selection = true }

function M.ticket(view, scope)
  assert(scopes[scope], "diffreel: unknown lifetime scope " .. tostring(scope))
  local manager = view.manager
  return {
    scope = scope,
    manager = manager,
    session_id = manager and manager.session_id,
    compare_seq = view.compare_seq,
    comparison_id = view.comparison and view.comparison.comparison_id,
    selection_seq = view.selection_seq,
  }
end

function M.current(view, ticket)
  if not M.valid(view) then
    return false
  end
  local manager = view.manager
  if manager ~= ticket.manager or (manager and manager.session_id) ~= ticket.session_id then
    return false
  end
  if ticket.scope == "manager" then
    return true
  end
  if ticket.scope == "comparison" then
    return view.compare_seq == ticket.compare_seq
  end
  if ticket.scope == "selection" then
    return view.selection_seq == ticket.selection_seq
      and (view.comparison and view.comparison.comparison_id) == ticket.comparison_id
  end
  error("diffreel: unknown lifetime scope " .. tostring(ticket.scope))
end

return M
