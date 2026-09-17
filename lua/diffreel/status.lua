local M = {}
local highlights = require("diffreel.highlights")
local namespace = vim.api.nvim_create_namespace("diffreel.status")
local windows = {}

function M.owns(win)
  return windows[win] == true
end

local function release(view)
  local state = view.status
  local win = view.explorer_win
  if not state or state.scrolloff == nil then
    return
  end
  local saved = state.scrolloff
  state.scrolloff = nil
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value("scrolloff", saved == false and -1 or saved, { win = win, scope = "local" })
  end
end

local function hide(view)
  local state = view.status
  if not state then
    return
  end
  local win = state.win
  state.win, state.geometry, state.parts = nil, nil, nil
  release(view)
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

function M.close(view)
  local state = view.status
  if state then
    state.pending = nil
  end
  hide(view)
end

function M.dispose(view)
  local state = view.status
  local ok, err = pcall(M.close, view)
  view.status = nil
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

-- Trailing padding only rescues the last buffer line: the cursor still reaches the window's
-- bottom row before Neovim scrolls, which would hide it under the overlay.
local function reserve(view, win, height)
  local state = view.status
  if state.scrolloff == nil then
    -- A window without a local value must get none back, or a later global change stops reaching it.
    local local_value = vim.api.nvim_get_option_value("scrolloff", { win = win, scope = "local" })
    state.scrolloff = local_value < 0 and false or local_value
  end
  local floor = state.scrolloff == false and vim.api.nvim_get_option_value("scrolloff", { win = win })
    or state.scrolloff
  vim.api.nvim_set_option_value("scrolloff", math.max(floor, height), { win = win, scope = "local" })
end

function M.capacity(win)
  local info = win and vim.api.nvim_win_is_valid(win) and vim.fn.getwininfo(win)[1]
  return info and math.max(1, math.floor(info.height / 2)) or 0
end

local function refresh(view, parts)
  local win = view.explorer_win
  if
    not view.alive
    or view.closing
    or view.layout_changing
    or #parts == 0
    or not win
    or not vim.api.nvim_win_is_valid(win)
    or vim.api.nvim_win_get_tabpage(win) ~= view.tab
    or vim.api.nvim_win_get_buf(win) ~= view.explorer_buf
  then
    M.close(view)
    return
  end
  local state = view.status
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    M.dispose(view)
    state = { buf = vim.api.nvim_create_buf(false, true) }
    view.status = state
    vim.api.nvim_buf_set_name(state.buf, "diffreel://" .. view.id .. "/status")
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].filetype = "diffreel-status"
  end
  state.pending = parts
  -- An editor-relative float lands in whatever tabpage is current, so a review waiting in
  -- another tab would draw its overlay over the tab being viewed. Hiding keeps what the
  -- review wants to show, so returning to its tab restores it.
  if vim.api.nvim_get_current_tabpage() ~= view.tab then
    hide(view)
    return
  end
  local info = vim.fn.getwininfo(win)[1]
  if not info or #parts > M.capacity(win) then
    M.close(view)
    return
  end
  -- relative="win" resolves its row differently depending on whether a tabline is present,
  -- so the bottom row is computed in editor coordinates the way full_name does.
  local bottom = info.winrow + info.winbar + info.height - 1
  local column = info.wincol + info.textoff
  if bottom > vim.o.lines or column > vim.o.columns or bottom - #parts < 0 then
    hide(view)
    return
  end
  local geometry = {
    relative = "editor",
    row = bottom - #parts,
    col = column - 1,
    width = math.max(1, info.width - info.textoff),
    height = #parts,
  }
  local texts = {}
  for i, part in ipairs(parts) do
    texts[i] = part.text
  end
  if not vim.deep_equal(state.parts, parts) or state.generation ~= highlights.generation then
    vim.bo[state.buf].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, texts)
    vim.bo[state.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(state.buf, namespace, 0, -1)
    for i, part in ipairs(parts) do
      if part.group then
        vim.api.nvim_buf_set_extmark(state.buf, namespace, i - 1, 0, {
          end_col = #part.text,
          hl_group = part.group,
        })
      end
    end
    state.parts, state.generation = vim.deepcopy(parts), highlights.generation
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
        -- help and path popups leave zindex unset, which defaults to 50.
        zindex = 45,
        noautocmd = true,
      })
    )
    windows[state.win] = true
    vim.wo[state.win].diff = false
    vim.wo[state.win].wrap = false
    vim.wo[state.win].winbar = ""
    vim.wo[state.win].cursorline = false
    vim.wo[state.win].winhighlight = "Normal:DiffreelExplorerNormal,NormalFloat:DiffreelExplorerNormal"
  elseif not vim.deep_equal(state.geometry, geometry) then
    vim.api.nvim_win_set_config(state.win, geometry)
  end
  state.geometry = geometry
  reserve(view, win, #parts)
end

-- winbar and statuscolumn changes move the bottom row without changing the content.
function M.reposition(view)
  local state = view.status
  M.update(view, state and state.pending or {})
end

function M.update(view, parts)
  local ok, err = pcall(refresh, view, parts or {})
  if not ok then
    pcall(M.dispose, view)
    vim.notify("diffreel: status overlay failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

return M
