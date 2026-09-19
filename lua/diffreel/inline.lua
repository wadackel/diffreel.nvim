local lifetime = require("diffreel.lifetime")
local M = {}
local pool, windows = {}, {}
local capability_namespace

local function anchors(win)
  local ok, value = pcall(vim.api.nvim_get_option_value, "diffanchors", { buf = vim.api.nvim_win_get_buf(win) })
  return ok and (value ~= "" and value or vim.go.diffanchors) or ""
end

function M.check(view)
  if type(vim.api.nvim__ns_set) ~= "function" or type(vim.api.nvim__ns_get) ~= "function" then
    return nil, "inline requires Neovim window-scoped namespaces"
  end
  capability_namespace = capability_namespace or vim.api.nvim_create_namespace("")
  local target = view and view.right_win or vim.api.nvim_get_current_win()
  local checked, scoped = pcall(function()
    vim.api.nvim__ns_set(capability_namespace, { wins = { target } })
    return vim.api.nvim__ns_get(capability_namespace).wins
  end)
  if not checked or not vim.deep_equal(scoped, { target }) then
    return nil, "inline window-scoped namespaces are unavailable"
  end
  local flags = vim.split(vim.o.diffopt, ",", { plain = true })
  if not vim.tbl_contains(flags, "internal") or vim.tbl_contains(flags, "icase") or vim.o.diffexpr ~= "" then
    return nil, "inline requires internal diff without icase or diffexpr"
  end
  for _, win in
    ipairs(view and { view.left_win, view.right_win, view.right_engine } or { vim.api.nvim_get_current_win() })
  do
    if anchors(win) ~= "" then
      return nil, "inline does not support diffanchors"
    end
  end
  return true
end

local function fingerprint(view)
  return {
    left = view.left_buf,
    right = view.right_buf,
    lt = vim.api.nvim_buf_get_changedtick(view.left_buf),
    rt = vim.api.nvim_buf_get_changedtick(view.right_buf),
    selection = view.selection_seq,
    path = view.selected_path,
    comparison = view.comparison and view.comparison.comparison_id,
    diffopt = vim.o.diffopt,
    diffexpr = vim.o.diffexpr,
    left_anchors = anchors(view.left_win),
    right_anchors = anchors(view.right_win),
    width = vim.api.nvim_win_get_width(view.right_win),
    textoff = vim.fn.getwininfo(view.right_win)[1].textoff,
    number = vim.wo[view.right_win].number,
    relativenumber = vim.wo[view.right_win].relativenumber,
    tabstop = vim.bo[view.left_buf].tabstop,
    vartabstop = vim.bo[view.left_buf].vartabstop,
    right_tabstop = vim.bo[view.right_buf].tabstop,
    right_vartabstop = vim.bo[view.right_buf].vartabstop,
    leftcol = vim.api.nvim_win_call(view.right_win, vim.fn.winsaveview).leftcol,
  }
end

function M.current(view)
  return view.inline_cache and vim.deep_equal(view.inline_cache.key, fingerprint(view))
end

function M.reveal_start(view)
  local first = view.inline_cache and view.inline_cache.deletions[1]
  if not first or first.after ~= 0 or vim.api.nvim_win_get_cursor(view.right_win)[1] ~= 1 then
    return
  end
  -- A topline of 1 with zero topfill hides virtual deletions above the first buffer line.
  vim.api.nvim_win_call(view.right_win, function()
    vim.fn.winrestview({ topline = 1, topfill = math.min(#first.lines, vim.api.nvim_win_get_height(0) - 1) })
  end)
end

local function fold_key(buf, path)
  return tostring(buf) .. ":" .. (path or "")
end

function M.capture_folds(view)
  if not vim.api.nvim_win_is_valid(view.right_win) or vim.api.nvim_win_get_buf(view.right_win) ~= view.right_buf then
    return
  end
  local cache = view.inline_cache
  local ranges = {}
  vim.api.nvim_win_call(view.right_win, function()
    if cache and cache.fold_ranges then
      for _, range in ipairs(cache.fold_ranges) do
        local mark =
          vim.api.nvim_buf_get_extmark_by_id(view.right_buf, view.inline_namespace, range.mark, { details = true })
        if #mark > 0 then
          local first, last = mark[1] + 1, mark[3].end_row
          ranges[first .. ":" .. last] = vim.fn.foldclosed(first) == -1
        end
      end
    else
      local row, count = 1, vim.api.nvim_buf_line_count(view.right_buf)
      while row <= count do
        if vim.fn.foldlevel(row) > 0 then
          local first, open = row, vim.fn.foldclosed(row) == -1
          repeat
            row = row + 1
          until row > count or vim.fn.foldlevel(row) == 0
          ranges[first .. ":" .. (row - 1)] = open
        else
          row = row + 1
        end
      end
    end
    view.inline_fold_states = view.inline_fold_states or {}
    view.inline_fold_states[fold_key(view.right_buf, cache and cache.key.path or view.selected_path)] =
      { ranges = ranges, level = vim.wo.foldlevel }
  end)
end

function M.restore_folds(view)
  local state = view.inline_fold_states and view.inline_fold_states[fold_key(view.right_buf, view.selected_path)]
  vim.api.nvim_win_call(view.right_win, function()
    local position = vim.fn.winsaveview()
    if state then
      vim.wo.foldlevel = state.level
    end
    vim.cmd("silent! normal! zx")
    if state then
      for key, open in pairs(state.ranges) do
        local first = tonumber(key:match("^(%d+):"))
        if first <= vim.api.nvim_buf_line_count(0) and vim.fn.foldlevel(first) > 0 then
          pcall(vim.cmd, first .. (open and "foldopen" or "foldclose"))
        end
      end
    end
    vim.fn.winrestview(position)
  end)
end

function M.clear(view)
  if view.inline_cache then
    pcall(M.capture_folds, view)
  end
  if view.inline_task and view.inline_task.restore then
    view.inline_task.restore()
  end
  view.inline_task, view.inline_pending, view.inline_cache = nil, nil, nil
  if view.inline_namespace then
    local remaining = {}
    for buf in pairs(view.inline_buffers or {}) do
      if vim.api.nvim_buf_is_valid(buf) then
        local ok = pcall(vim.api.nvim_buf_clear_namespace, buf, view.inline_namespace, 0, -1)
        if not ok then
          remaining[buf] = true
        end
      end
    end
    view.inline_buffers = remaining
  end
end

function M.dispose(view)
  M.clear(view)
  windows[view.right_win] = nil
  if view.inline_namespace then
    if not next(view.inline_buffers or {}) then
      pool[#pool + 1] = view.inline_namespace
    end
    view.inline_namespace, view.inline_buffers = nil, nil
  end
end

function M.fold(row)
  local view = windows[vim.api.nvim_get_current_win()]
  return view and view.inline_cache and (view.inline_cache.folds[row] or 0) or 0
end

local function diff_options()
  local result = { result_type = "indices", ctxlen = 0, interhunkctxlen = 0 }
  local flags = {
    iwhite = "ignore_whitespace_change",
    iwhiteall = "ignore_whitespace",
    iwhiteeol = "ignore_whitespace_change_at_eol",
    iblank = "ignore_blank_lines",
    ["indent-heuristic"] = "indent_heuristic",
  }
  for flag in vim.o.diffopt:gmatch("[^,]+") do
    if flags[flag] then
      result[flags[flag]] = true
    end
    local algorithm = flag:match("^algorithm:(.+)$")
    if algorithm then
      result.algorithm = algorithm
    end
  end
  return result
end

local function expand_tabs(chunks, win, checkpoint)
  local column, pending = 0, ""
  for _, chunk in ipairs(chunks) do
    local parts, offset = {}, 1
    for position in chunk[1]:gmatch("()\t") do
      local segment = chunk[1]:sub(offset, position - 1)
      pending = pending .. segment
      local widths = vim.api.nvim_win_call(win, function()
        return { vim.fn.strdisplaywidth(pending, column), vim.fn.strdisplaywidth(pending .. "\t", column) }
      end)
      parts[#parts + 1] = segment .. string.rep(" ", widths[2] - widths[1])
      column, pending, offset = column + widths[2], "", position + 1
      checkpoint()
    end
    local tail = chunk[1]:sub(offset)
    pending = pending .. tail
    parts[#parts + 1] = tail
    chunk[1] = table.concat(parts)
  end
end

function M.compute(view, engines, done)
  view.inline_task = {}
  local task, key = view.inline_task, fingerprint(view)
  local positions = {}
  for _, win in ipairs(engines) do
    positions[win] = {
      buf = vim.api.nvim_win_get_buf(win),
      position = vim.api.nvim_win_call(win, vim.fn.winsaveview),
      foldenable = vim.wo[win].foldenable,
    }
  end
  task.restore = function()
    for win, saved in pairs(positions) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == saved.buf then
        pcall(vim.api.nvim_win_call, win, function()
          vim.wo[win].foldenable = saved.foldenable
          vim.fn.winrestview(saved.position)
        end)
      end
    end
  end
  view.inline_pending = true
  local function current()
    if view.inline_task ~= task or not lifetime.valid(view) or view.navigation then
      return false
    end
    for _, win in ipairs(engines) do
      if not vim.api.nvim_win_is_valid(win) then
        return false
      end
    end
    return vim.deep_equal(key, fingerprint(view))
  end
  local started
  local function checkpoint()
    if vim.uv.hrtime() - started > 8e6 then
      coroutine.yield()
    end
  end
  local worker = coroutine.create(function()
    local compatible, reason = M.check(view)
    assert(compatible, reason)
    for _, buf in ipairs({ view.left_buf, view.right_buf }) do
      local count = vim.api.nvim_buf_line_count(buf)
      assert(
        count <= 20000 and vim.api.nvim_buf_get_offset(buf, count) <= 1048576,
        "inline content exceeds 1 MiB or 20,000 lines per side"
      )
    end
    local cache = { key = key, folds = {}, left = {}, right = {}, deletions = {} }
    local entry = view.by_path and view.by_path[view.selected_path]
    if not entry or not vim.wo[engines[1]].diff or not vim.wo[engines[2]].diff then
      return cache
    end
    local lines = {
      vim.api.nvim_buf_get_lines(view.left_buf, 0, -1, false),
      vim.api.nvim_buf_get_lines(view.right_buf, 0, -1, false),
    }
    -- Buffer line diff ignores BOM/EOF metadata; omitted Lua linematch avoids a different whitespace refinement.
    local ranges =
      vim.text.diff(table.concat(lines[1], "\n") .. "\n", table.concat(lines[2], "\n") .. "\n", diff_options())
    for _, hunk in ipairs(ranges) do
      for side, win in ipairs(engines) do
        local index = side == 1 and 1 or 3
        if hunk[index + 1] > 0 then
          vim.api.nvim_win_call(win, function()
            vim.fn.winrestview({ topline = hunk[index], lnum = hunk[index], col = 0, topfill = 0 })
            vim.fn.line("w$")
            vim.fn.diff_hlID(hunk[index], 1)
          end)
        end
        checkpoint()
      end
    end
    local coverage = { {}, {} }
    for _, hunk in ipairs(ranges) do
      for side = 1, 2 do
        local offset = side == 1 and 1 or 3
        for row = hunk[offset], hunk[offset] + hunk[offset + 1] - 1 do
          coverage[side][row] = true
        end
      end
    end
    local text_ids =
      { [vim.api.nvim_get_hl_id_by_name("DiffText")] = true, [vim.api.nvim_get_hl_id_by_name("DiffTextAdd")] = true }
    local visible = vim.api.nvim_win_call(view.right_win, vim.fn.winsaveview)
    local width = vim.api.nvim_win_get_width(view.right_win)
    vim.api.nvim_win_call(engines[2], function()
      vim.wo.foldenable = true
      vim.cmd("silent! normal! zx")
    end)
    for side, win in ipairs(engines) do
      local data, name = entry[side == 1 and "left" or "right"], side == 1 and "left" or "right"
      local draft = side == 2 and view.right_buf ~= view.empty_buf and vim.bo[view.right_buf].modified
      local real = draft or (data.kind ~= "missing" and data.kind ~= "limited" and data.size ~= 0)
      for row, line in ipairs(lines[side]) do
        local item = vim.api.nvim_win_call(win, function()
          local changed = vim.fn.diff_hlID(row, 1) > 0
          assert(
            not real or not changed or coverage[side][row],
            "inline could not represent the native diff; use a split layout"
          )
          if side == 2 then
            cache.folds[row] = vim.fn.foldlevel(row)
          end
          if not changed or not real then
            return
          end
          local chunks, spans = {}, {}
          local first = math.max(1, vim.fn.virtcol2col(win, row, (visible.leftcol or 0) + 1))
          local last = vim.fn.virtcol2col(win, row, (visible.leftcol or 0) + width + 1)
          last = last > 0 and last or #line
          local base_group = side == 1 and "DiffreelLineDelete" or "DiffreelLineAdd"
          if first > 1 then
            chunks[#chunks + 1] = { line:sub(1, first - 1), base_group }
          end
          local position = first
          local group, begin = nil, first
          while position <= #line and position <= last do
            local marked = position >= first and position <= last and text_ids[vim.fn.diff_hlID(row, position)]
            local next_group = "Diffreel" .. (marked and "Text" or "Line") .. (side == 1 and "Delete" or "Add")
            if next_group ~= group then
              if group then
                chunks[#chunks + 1] = { line:sub(begin, position - 1), group }
                if group:find("Text", 1, true) then
                  spans[#spans + 1] = { begin - 1, position - 1, group }
                end
              end
              group, begin = next_group, position
            end
            local byte = line:byte(position)
            position = position + (byte < 128 and 1 or byte < 224 and 2 or byte < 240 and 3 or 4)
          end
          chunks[#chunks + 1] = { line:sub(begin, position - 1), group or base_group }
          if group and group:find("Text", 1, true) then
            spans[#spans + 1] = { begin - 1, position - 1, group }
          end
          if position <= #line then
            chunks[#chunks + 1] = { line:sub(position), base_group }
          end
          return { row = row, chunks = chunks, spans = spans }
        end)
        if item and side == 1 then
          -- Virtual lines include the gutter, which otherwise shifts their tab stops relative to buffer text.
          expand_tabs(item.chunks, win, checkpoint)
        end
        cache[name][row] = item
        checkpoint()
      end
    end
    for _, hunk in ipairs(ranges) do
      local removed = {}
      for row = hunk[1], hunk[1] + hunk[2] - 1 do
        if cache.left[row] then
          removed[#removed + 1] = cache.left[row]
        end
      end
      if #removed > 0 then
        local after = hunk[4] == 0 and hunk[3] or hunk[3] - 1
        cache.deletions[#cache.deletions + 1] = { after = after, lines = removed }
      end
    end
    return cache
  end)
  local function step()
    if not current() then
      if view.inline_task == task then
        task.restore()
        view.inline_task, view.inline_pending = nil, nil
        done("inline inputs changed", nil, true)
      end
      return
    end
    started = vim.uv.hrtime()
    local ok, result = coroutine.resume(worker)
    if view.inline_task ~= task then
      return
    end
    if not current() then
      task.restore()
      view.inline_task, view.inline_pending = nil, nil
      done("inline inputs changed", nil, true)
      return
    end
    if not ok or coroutine.status(worker) == "dead" then
      task.restore()
      view.inline_task, view.inline_pending = nil, nil
      done(not ok and tostring(result) or nil, ok and result or nil)
    else
      vim.schedule(step)
    end
  end
  vim.schedule(step)
end

function M.attach(view, cache)
  local ns = view.inline_namespace
  if not ns then
    ns = table.remove(pool) or vim.api.nvim_create_namespace("")
    view.inline_namespace = ns
  end
  M.clear(view)
  vim.api.nvim__ns_set(ns, { wins = { view.right_win } })
  view.inline_cache = cache
  windows[view.right_win] = view
  view.inline_buffers = view.inline_buffers or {}
  view.inline_buffers[view.right_buf] = true
  local buf = view.right_buf
  local offset = vim.fn.getwininfo(view.right_win)[1].textoff
  local count = vim.api.nvim_buf_line_count(buf)
  for _, block in ipairs(cache.deletions) do
    local lines = {}
    for _, item in ipairs(block.lines) do
      local numbered = vim.wo[view.right_win].number or vim.wo[view.right_win].relativenumber
      local prefix = offset == 0 and "" or offset == 1 and "-" or (string.rep(" ", offset - 2) .. "- ")
      if numbered and #tostring(item.row) <= offset - 2 then
        prefix = string.format("%" .. (offset - 2) .. "d- ", item.row)
      end
      local chunks = { { prefix, "DiffreelInlineDeleteNumber" } }
      vim.list_extend(chunks, item.chunks)
      lines[#lines + 1] = chunks
    end
    local eof = block.after >= count
    vim.api.nvim_buf_set_extmark(buf, ns, eof and count - 1 or math.max(0, block.after), 0, {
      virt_lines = lines,
      virt_lines_above = not eof,
      virt_lines_leftcol = true,
      virt_lines_overflow = "scroll",
    })
  end
  for row, item in pairs(cache.right) do
    vim.api.nvim_buf_set_extmark(
      buf,
      ns,
      row - 1,
      0,
      { end_row = row, hl_group = "DiffreelLineAdd", hl_eol = true, priority = 90 }
    )
    for _, span in ipairs(item.spans) do
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, span[1], { end_col = span[2], hl_group = span[3], priority = 100 })
    end
  end
  cache.fold_ranges = {}
  local row = 1
  while row <= count do
    if (cache.folds[row] or 0) > 0 then
      local first = row
      repeat
        row = row + 1
      until row > count or (cache.folds[row] or 0) == 0
      local mark = vim.api.nvim_buf_set_extmark(
        buf,
        ns,
        first - 1,
        0,
        { end_row = row - 1, right_gravity = false, end_right_gravity = false }
      )
      cache.fold_ranges[#cache.fold_ranges + 1] = { first = first, last = row - 1, mark = mark }
    else
      row = row + 1
    end
  end
  M.restore_folds(view)
  M.reveal_start(view)
end

return M
