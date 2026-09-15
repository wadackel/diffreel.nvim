local M = {}
local namespace = vim.api.nvim_create_namespace("diffreel.popup")

function M.close(view, key)
  key = key or "help"
  local popup = view[key]
  if not popup then
    return
  end
  view[key] = nil
  local focused = vim.api.nvim_get_current_win() == popup.win
  local ok, err = true, nil
  if popup.win and vim.api.nvim_win_is_valid(popup.win) then
    ok, err = pcall(vim.api.nvim_win_close, popup.win, true)
  end
  if vim.api.nvim_buf_is_valid(popup.buf) then
    local removed, failure = pcall(vim.api.nvim_buf_delete, popup.buf, { force = true })
    if not removed then
      ok, err = false, failure
    end
  end
  if
    focused
    and vim.api.nvim_win_is_valid(popup.origin)
    and vim.api.nvim_win_get_tabpage(popup.origin) == vim.api.nvim_get_current_tabpage()
  then
    vim.api.nvim_set_current_win(popup.origin)
  end
  if not ok then
    error(err)
  end
end

function M.open(view, key, title, lines, keys, highlights)
  M.close(view, key)
  local width = 38
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(1, math.min(width, vim.o.columns - 4))
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  height = math.max(1, math.min(height, vim.o.lines - vim.o.cmdheight - 4))
  local origin = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  local popup = { buf = buf, origin = origin }
  view[key] = popup
  local ok, err = xpcall(function()
    vim.api.nvim_buf_set_name(buf, "diffreel://" .. view.id .. "/" .. key)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = key == "help" and "diffreel-help" or "diffreel-path"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    if key == "path_popup" then
      for row, line in ipairs(lines) do
        vim.api.nvim_buf_set_extmark(buf, namespace, row - 1, 0, { end_col = #line, hl_group = "DiffreelPathText" })
      end
    end
    for _, span in ipairs(highlights or {}) do
      vim.api.nvim_buf_set_extmark(buf, namespace, span.row, span.first, { end_col = span.last, hl_group = span.group })
    end
    vim.bo[buf].modifiable = false
    popup.win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      title = title,
      title_pos = "center",
      width = width,
      height = height,
      row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
      col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    })
    local scope = key == "help" and "Help" or "Path"
    vim.wo[popup.win].winhighlight = "Normal:Diffreel"
      .. scope
      .. "Normal,NormalFloat:Diffreel"
      .. scope
      .. "Normal,FloatBorder:Diffreel"
      .. scope
      .. "Border,FloatTitle:Diffreel"
      .. scope
      .. "Title"
    vim.wo[popup.win].wrap = true
    for _, lhs in ipairs(keys) do
      vim.keymap.set("n", lhs, function()
        M.close(view, key)
      end, { buffer = buf, silent = true, nowait = true })
    end
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(popup.win),
      once = true,
      callback = function()
        if view[key] == popup then
          view[key] = nil
        end
      end,
    })
  end, debug.traceback)
  if not ok then
    pcall(M.close, view, key)
    error(err)
  end
end

return M
