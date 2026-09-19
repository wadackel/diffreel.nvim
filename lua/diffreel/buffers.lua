local lease = require("diffreel.lease")
local presentation = require("diffreel.presentation")
local M = {}
local buffer_operations = 0

local function with_buffer_operation(action)
  buffer_operations = buffer_operations + 1
  local ok, err = pcall(action)
  buffer_operations = buffer_operations - 1
  if not ok then
    error(err, 0)
  end
end

local function busy()
  return buffer_operations > 0
end

local function owned_buffer(name, allocated)
  local buf = vim.api.nvim_create_buf(false, true)
  allocated[#allocated + 1] = buf
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
end

local function put_virtual(view, side, data, path)
  local buf = side == "left" and view.left_buf or view.empty_buf
  if path and view.manager and view.comparison then
    -- Renaming a reused buffer creates an unowned alternate-name buffer, even with keepalt.
    vim.b[buf].diffreel_root, vim.b[buf].diffreel_path = view.manager.root, path
  end
  local lines = data.lines
    or {
      "Not compared: " .. (data.reason or data.kind),
      "Mode: " .. (data.mode or "?"),
      "Size: " .. ((data.size and data.size > 0) and (data.size .. " bytes") or "not read"),
      data.oid and ("Object: " .. data.oid) or "",
    }
  set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.bo[buf].endofline = data.endofline or false
  vim.bo[buf].fileformat = data.fileformat or "unix"
  vim.bo[buf].bomb = data.bom or false
  vim.bo[buf].modified = false
  vim.bo[buf].modifiable = false
  local lang
  if data.kind == "text" and path then
    local ft = vim.filetype.match({ filename = path })
    lang = ft and vim.treesitter.language.get_lang(ft)
  end
  if lang ~= vim.b[buf].diffreel_language then
    pcall(vim.treesitter.stop, buf)
    vim.b[buf].diffreel_language = nil
    if lang and pcall(vim.treesitter.start, buf, lang) then
      vim.b[buf].diffreel_language = lang
    end
  end
  return buf
end

local function release_right(view, previous)
  if previous and previous ~= view.empty_buf and previous ~= view.right_buf then
    lease.release(previous, view.id)
  end
end

local function buffer_hash(buf)
  local borrowed = lease.buffers[buf]
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local format, bomb, eol = vim.bo[buf].fileformat, vim.bo[buf].bomb, vim.bo[buf].endofline
  local cached = borrowed and borrowed.content_hash
  if cached and cached.tick == tick and cached.format == format and cached.bomb == bomb and cached.eol == eol then
    return cached.value
  end
  local newline = format == "dos" and "\r\n" or "\n"
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local data = table.concat(lines, newline)
  local bom = bomb and string.char(239, 187, 191) or ""
  local empty = #lines == 1
    and lines[1] == ""
    and vim.api.nvim_buf_call(buf, function()
      return vim.fn.wordcount().bytes <= #bom
    end)
  if eol and not empty then
    data = data .. newline
  end
  local value = vim.fn.sha256(bom .. data)
  if borrowed then
    borrowed.content_hash = { tick = tick, format = format, bomb = bomb, eol = eol, value = value }
  end
  return value
end

local function set_review_buffer(view, win, buf)
  if vim.api.nvim_win_get_buf(win) == buf then
    return
  end
  with_buffer_operation(function()
    if vim.wo[win].diff then
      -- Replacing a diff window's buffer leaves the hidden buffer in the tab's comparison.
      vim.api.nvim_win_call(win, function()
        presentation.diffoff(view, win)
      end)
    end
    presentation.restore(view, win)
    lease.preserve_buffer(buf, function()
      vim.api.nvim_win_set_buf(win, buf)
    end)
  end)
end

local function set_right_buffer(view, buf)
  if view.right_engine then
    set_review_buffer(view, view.right_engine, buf)
  end
  set_review_buffer(view, view.right_win, buf)
end

local observed_buffers = {}
local function observe_buffer(buf, on_change)
  -- Only the first callback per buffer is kept; a later caller with a different callback would be dropped silently.
  if observed_buffers[buf] then
    return
  end
  observed_buffers[buf] = vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, changed)
      if not lease.buffers[changed] then
        observed_buffers[changed] = nil
        return true
      end
      on_change(changed)
    end,
    on_reload = function(_, changed)
      on_change(changed)
    end,
    on_detach = function(_, detached)
      observed_buffers[detached] = nil
    end,
  }) or nil
end

M.with_operation, M.owned_buffer, M.set_lines, M.put_virtual =
  with_buffer_operation, owned_buffer, set_lines, put_virtual
M.release_right, M.buffer_hash, M.set_review_buffer, M.set_right_buffer =
  release_right, buffer_hash, set_review_buffer, set_right_buffer
M.observe, M.busy = observe_buffer, busy

return M
