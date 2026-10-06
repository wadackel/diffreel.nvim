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

return M
