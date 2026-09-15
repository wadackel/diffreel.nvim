local M = {}
local explorer = require("diffreel.explorer")
local highlights = require("diffreel.highlights")
local namespace = vim.api.nvim_create_namespace("diffreel.full_name")
local windows = {}

function M.owns(win)
  return windows[win] == true
end

function M.close(view)
  local state = view.full_name
  if not state then
    return
  end
  local win = state.win
  state.win, state.geometry, state.row = nil, nil, nil
  if win then
    local ok, err = true, nil
    if vim.api.nvim_win_is_valid(win) then
      ok, err = pcall(vim.api.nvim_win_close, win, true)
    end
    windows[win] = nil
    if not ok then
      error(err)
    end
  end
end

function M.dispose(view)
  local state = view.full_name
  local ok, err = pcall(M.close, view)
  view.full_name = nil
  if state and vim.api.nvim_buf_is_valid(state.buf) then
    local removed, failure = pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
    if not removed then
      ok, err = false, failure
    end
  end
  if not ok then
    error(err)
  end
end

local function refresh(view)
  local win = view.explorer_win
  if
    not view.alive
    or view.closing
    or view.layout_changing
    or not view.explorer_options.full_name
    or not win
    or not vim.api.nvim_win_is_valid(win)
    or vim.api.nvim_get_current_win() ~= win
    or vim.api.nvim_get_current_tabpage() ~= view.tab
    or vim.api.nvim_win_get_buf(win) ~= view.explorer_buf
    or view.help
    or view.path_popup
    or vim.wo[win].wrap
    or vim.api.nvim_win_call(win, vim.fn.winsaveview).leftcol ~= 0
  then
    M.close(view)
    return
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local row = view.rows and view.rows[line - 3]
  local info = vim.fn.getwininfo(win)[1]
  local width = row and vim.fn.strdisplaywidth(row.full.text) or 0
  if not row or not info or (not row.truncated and width <= info.width - info.textoff) then
    M.close(view)
    return
  end
  local position = vim.fn.screenpos(win, line, 1)
  if position.row == 0 or position.col == 0 or position.col > vim.o.columns then
    M.close(view)
    return
  end
  local geometry = {
    relative = "editor",
    row = position.row - 1,
    col = position.col - 1,
    width = math.min(width, vim.o.columns - position.col + 1),
    height = 1,
  }
  local state = view.full_name
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    M.dispose(view)
    state = { buf = vim.api.nvim_create_buf(false, true) }
    view.full_name = state
    vim.api.nvim_buf_set_name(state.buf, "diffreel://" .. view.id .. "/full-name")
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].filetype = "diffreel-full-name"
  end
  if state.row ~= row or state.selected ~= view.selected_path or state.generation ~= highlights.generation then
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { row.full.text })
    vim.bo[state.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
    explorer.highlight(state.buf, namespace, 0, row, view.selected_path, true)
    state.row, state.selected, state.generation = row, view.selected_path, highlights.generation
  end
  if not state.win or not vim.api.nvim_win_is_valid(state.win) then
    if state.win then
      windows[state.win] = nil
    end
    state.win = vim.api.nvim_open_win(
      state.buf,
      false,
      vim.tbl_extend("force", geometry, {
        style = "minimal",
        border = "none",
        focusable = false,
        mouse = false,
        zindex = 51,
        noautocmd = true,
      })
    )
    windows[state.win] = true
    vim.wo[state.win].diff = false
    vim.wo[state.win].wrap = false
    vim.wo[state.win].winbar = ""
    vim.wo[state.win].cursorlineopt = "line"
    vim.wo[state.win].winhighlight =
      "Normal:DiffreelExplorerNormal,NormalFloat:DiffreelExplorerNormal,CursorLine:DiffreelExplorerCursorLine"
  elseif not vim.deep_equal(state.geometry, geometry) then
    vim.api.nvim_win_set_config(state.win, geometry)
  end
  vim.wo[state.win].cursorline = vim.wo[win].cursorline
  state.geometry = geometry
end

function M.update(view)
  if view.full_name_pending then
    return
  end
  view.full_name_pending = true
  vim.schedule(function()
    view.full_name_pending = nil
    local ok, err = pcall(refresh, view)
    if not ok then
      pcall(M.dispose, view)
      vim.notify("diffreel: full name display failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end)
end

return M
