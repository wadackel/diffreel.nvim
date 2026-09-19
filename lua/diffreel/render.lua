local explorer = require("diffreel.explorer")
local presentation = require("diffreel.presentation")
local highlights = require("diffreel.highlights")
local spinner = require("diffreel.spinner")
local line_stats = require("diffreel.line_stats")
local full_name = require("diffreel.full_name")
local windows = require("diffreel.windows")
local lifetime = require("diffreel.lifetime")
local phase = require("diffreel.phase")
local ui = require("diffreel.ui")
local buffers = require("diffreel.buffers")
local M = {}
local namespace = vim.api.nvim_create_namespace("diffreel")
local valid = lifetime.valid
local set_lines, buffer_hash = buffers.set_lines, buffers.buffer_hash

local function title(view)
  if view.pr then
    return ui.label(
      view.ui_icons,
      "pull_request",
      "PR #" .. view.pr.number .. " · " .. view.pr.state .. " · " .. explorer.display(view.pr.title)
    )
  elseif view.pr_target then
    return ui.label(view.ui_icons, "pull_request", "PR " .. explorer.display(tostring(view.pr_target)))
  end
  local left = view.comparison and view.comparison.left or view.spec.left
  local right = view.comparison and view.comparison.right or view.spec.right
  local left_label = view.follow_head and ui.label(view.ui_icons, left == "" and "empty" or "commit", "HEAD")
    or ui.endpoint(view.ui_icons, left, vim.fn.strcharpart(left, 0, 10))
  return left_label .. " → " .. ui.endpoint(view.ui_icons, right, vim.fn.strcharpart(right, 0, 10))
end

local function format_label(side)
  if side.reason then
    return side.reason
  elseif side.exists == false then
    return ""
  end
  return (side.fileformat == "dos" and "CRLF" or "LF")
    .. (side.bom and " · BOM" or "")
    .. (side.endofline == false and " · no final newline" or "")
end

local function header_path(path)
  local display = explorer.display(path):gsub("%%", "%%%%")
  local directory, name = display:match("^(.*[/])([^/]*)$")
  return " %<%#DiffreelDiffWinbarDirectory#"
    .. (directory or "")
    .. "%#DiffreelDiffWinbarPath#"
    .. (name or display)
    .. "%*"
end

local function activity(view)
  if view.error then
    return "Error", "R: retry"
  elseif view.navigation then
    return "Paused", ui.label(view.ui_icons, "paused", "Paused")
  elseif not view.ready then
    -- The pane's own Loading header already spins; a second indicator would only repeat it.
    return
  end
  local group, text
  if view.updating then
    group, text = "", "Updating…"
  elseif view.line_stats then
    local stats = line_stats.current(view)
    if not stats or stats.pending then
      group, text = "", "Counting saved lines…"
    end
  end
  if text then
    return group, ui.prefix(spinner.frame() or ui.icon(view.ui_icons, "loading"), text)
  end
end

-- The review-wide label follows whichever owned pane sits top-right, rather than living in the
-- explorer, which can be hidden or scrolled away while the review is still working.
local function refresh_headers(view)
  local headers, target, corner = view.headers or {}, nil, nil
  for win, state in pairs(headers) do
    if
      not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_tabpage(win) ~= view.tab
      or (state.value and vim.wo[win].winbar ~= state.value)
    then
      headers[win] = nil
    elseif vim.api.nvim_win_get_config(win).relative == "" then
      local position = vim.api.nvim_win_get_position(win)
      local right = position[2] + vim.api.nvim_win_get_width(win)
      if not corner or position[1] < corner[1] or (position[1] == corner[1] and right > corner[2]) then
        target, corner = win, { position[1], right }
      end
    end
  end
  local group, label = activity(view)
  for win, state in pairs(headers) do
    local value = state.left .. "%=" .. (state.right or "")
    if win == target and label then
      -- A dim label between the path and the endpoint read as part of the header, so it takes
      -- the far edge in a status color instead.
      value = value .. "%#DiffreelActivity" .. group .. "# " .. ui.winbar(label) .. " %* "
    end
    if value ~= state.value then
      presentation.header(view, win, value)
      if vim.wo[win].winbar == value then
        state.value = value
      else
        headers[win] = nil
      end
    end
  end
end

local function header(view, win, left, right)
  view.headers = view.headers or {}
  local state = view.headers[win]
  -- A pane restored while paused must be claimed again, not skipped as someone else's winbar.
  local value = state and vim.api.nvim_win_is_valid(win) and vim.wo[win].winbar == state.value and state.value or nil
  view.headers[win] = { left = left, right = right, value = value }
  refresh_headers(view)
end

local function render(view, cursor_path, frame_only)
  if not valid(view) or not vim.api.nvim_buf_is_valid(view.explorer_buf) then
    return
  end
  if view.error or not view.ready then
    local label = view.error and ui.label(view.ui_icons, "error", "Update stopped: " .. explorer.display(view.error))
      or ui.prefix(spinner.frame() or ui.icon(view.ui_icons, "loading"), "Loading " .. title(view))
    local group = view.error and "DiffreelExplorerError" or "DiffreelDiffWinbarState"
    header(
      view,
      view.layout == "inline" and view.right_win or view.left_win,
      " %#" .. group .. "#%<" .. ui.winbar(label) .. "%*"
    )
  end
  if view.layout_changing then
    return
  end
  if not windows.explorer_visible(view) then
    refresh_headers(view)
    return
  end
  local position = vim.api.nvim_win_call(view.explorer_win, vim.fn.winsaveview)
  local old_rows = view.rows
  local old = old_rows and old_rows[position.lnum - 3]
  local footer_anchor = ui.anchor(view.footer_rows, position.lnum, position.col)
  local width = vim.api.nvim_win_get_width(view.explorer_win)
  local lines = {
    " " .. ui.label(view.ui_icons, "repository", explorer.display(vim.fs.basename(view.root))),
    " " .. title(view),
    "",
  }
  local rows, tree = explorer.rows(
    view.entries or {},
    view.collapsed,
    width,
    view.tree,
    line_stats.files(view),
    view.explorer_options,
    view.ui_icons
  )
  local count = #(view.entries or {})
  local position_label = ""
  for i, entry in ipairs(explorer.ordered(tree, view.explorer_options.mode)) do
    if entry.path == view.selected_path then
      position_label = i .. " / "
      break
    end
  end
  header(
    view,
    view.explorer_win,
    " %#DiffreelExplorerTitle#" .. ui.winbar(ui.label(view.ui_icons, "changes", "Changes")) .. "%*",
    "%#DiffreelExplorerFileCount# " .. position_label .. count .. " %*"
  )
  view.rows, view.tree = rows, tree
  for _, row in ipairs(rows) do
    lines[#lines + 1] = row.text
  end
  local details, footer_rows = {}, {}
  local function append(text, group, id, icon)
    -- Overlaying the frame as a separate extmark would land it on the continuation lines
    -- ui.wrap produces, so the frame replaces the icon in the slot ui.label already reserves.
    local glyph = icon == "loading" and not view.error and spinner.frame() or nil
    local label = icon and (glyph and ui.prefix(glyph, text) or ui.label(view.ui_icons, icon, text)) or text
    for _, part in ipairs(ui.wrap(label, width)) do
      lines[#lines + 1] = part.text
      part.id = id or group
      footer_rows[#lines] = part
      if group then
        details[#details + 1] = { row = #lines - 1, group = "DiffreelExplorer" .. group }
      end
    end
  end
  if #rows == 0 then
    append(
      view.error and "Update stopped" or (view.updating and "Loading…" or "No changes"),
      view.error and "Error" or (view.updating and "Loading" or "Empty"),
      "empty",
      view.error and "error" or (view.updating and "loading" or "clean")
    )
  end
  lines[#lines + 1] = ""
  local selected = view.selected_path and view.by_path[view.selected_path]
  if view.line_stats then
    local stats = line_stats.current(view)
    if stats then
      append(
        "Saved lines: +"
          .. stats.additions
          .. " -"
          .. stats.deletions
          .. ((stats.pending or stats.unavailable > 0 or stats.error) and " · partial" or ""),
        "Summary",
        "summary",
        "changes"
      )
      if stats.error then
        append(
          "Line counts unavailable: " .. explorer.display(stats.error),
          "StatsUnavailable",
          "stats_error",
          "warning"
        )
      elseif selected then
        local value = stats.files[selected.path]
        local reason = selected.buffer_only and "unsaved-only file" or (value and value.reason)
        if reason then
          append("Line counts: " .. explorer.display(reason), "StatsUnavailable", "stats_reason", "warning")
        end
      end
    end
  end
  if selected and selected.git and selected.git.submodule_state then
    local state = selected.git.submodule_state
    append("Submodule:", "Detail", "submodule")
    if state:sub(2, 2) == "C" then
      append("  commit changed", "Detail", "submodule_commit")
    end
    if state:sub(3, 3) == "M" then
      append("  tracked changes", "Detail", "submodule_tracked")
    end
    if state:sub(4, 4) == "U" then
      append("  untracked files", "Detail", "submodule_untracked")
    end
  end
  if selected and selected.left.exists and selected.right.exists then
    if selected.left.mode ~= selected.right.mode then
      append("Mode: " .. selected.left.mode .. " → " .. selected.right.mode, "Detail", "mode")
    end
    if
      selected.left.kind == "text"
      and selected.right.kind == "text"
      and format_label(selected.left) ~= format_label(selected.right)
    then
      append(format_label(selected.left) .. " → " .. format_label(selected.right), "Detail", "format")
    end
  end
  if view.error then
    append("Update stopped: " .. explorer.display(view.error), "Error", "error", "error")
  elseif view.disk_conflict then
    append("Unsaved buffer differs from disk", "Conflict", "conflict", "warning")
  elseif view.navigation then
    append("Return to source or select a file", "Paused", "paused_hint")
  end
  local rendered = view.explorer_render
  if
    not rendered
    or rendered.generation ~= highlights.generation
    or rendered.rows ~= rows
    or rendered.selected_path ~= view.selected_path
    or rendered.tick ~= vim.api.nvim_buf_get_changedtick(view.explorer_buf)
    or not vim.deep_equal(rendered.lines, lines)
  then
    set_lines(view.explorer_buf, lines)
    vim.api.nvim_buf_clear_namespace(view.explorer_buf, namespace, 0, -1)
    vim.api.nvim_buf_set_extmark(
      view.explorer_buf,
      namespace,
      0,
      0,
      { end_row = 1, hl_group = "DiffreelExplorerRootName" }
    )
    vim.api.nvim_buf_set_extmark(
      view.explorer_buf,
      namespace,
      1,
      0,
      { end_row = 2, hl_group = "DiffreelExplorerComparison" }
    )
    for _, item in ipairs(details) do
      vim.api.nvim_buf_set_extmark(view.explorer_buf, namespace, item.row, 0, {
        end_col = #lines[item.row + 1],
        hl_group = item.group,
      })
    end
    for i, row in ipairs(rows) do
      explorer.highlight(view.explorer_buf, namespace, i + 2, row, view.selected_path)
    end
    view.explorer_render = {
      generation = highlights.generation,
      details = details,
      rows = rows,
      selected_path = view.selected_path,
      lines = lines,
      tick = vim.api.nvim_buf_get_changedtick(view.explorer_buf),
    }
  end
  refresh_headers(view)
  view.footer_rows = footer_rows
  if frame_only then
    return
  end
  local explicit = cursor_path or view.reveal_path
  local target = explorer.cursor_path(rows, explicit or (old and old.path) or view.selected_path)
  if not explicit and footer_anchor then
    local row, col = ui.locate(footer_rows, footer_anchor)
    row = row or math.min(#lines, math.max(#rows + 4, position.lnum + #rows - #old_rows))
    position.topline = math.max(1, position.topline + row - position.lnum)
    position.lnum, position.col = row, col or position.col
    vim.api.nvim_win_call(view.explorer_win, function()
      vim.fn.winrestview(position)
    end)
  elseif not explicit and old_rows and #old_rows > 0 and not old then
    if position.lnum > 3 then
      position.lnum = position.lnum + #rows - #old_rows
    end
    position.lnum = math.min(#lines, math.max(1, position.lnum))
    vim.api.nvim_win_call(view.explorer_win, function()
      vim.fn.winrestview(position)
    end)
  else
    for i, row in ipairs(rows) do
      if row.path == target then
        if not explicit and old and old.path == target then
          position.topline = math.max(1, position.topline + i + 3 - position.lnum)
          position.lnum = i + 3
          vim.api.nvim_win_call(view.explorer_win, function()
            vim.fn.winrestview(position)
          end)
        else
          vim.api.nvim_win_set_cursor(view.explorer_win, { i + 3, 0 })
        end
        break
      end
    end
  end
  view.reveal_path = nil
  full_name.update(view)
end

local function loading(view)
  -- A stopped review never animates: line_stats.start only runs from init.lua's ready(), which
  -- requires no error, so a pending counter on an errored view would never resolve.
  if not valid(view) or view.closing or view.error then
    return false
  end
  if view.updating or not view.ready then
    return true
  end
  if not view.line_stats then
    return false
  end
  local stats = line_stats.current(view)
  return not stats or stats.pending == true
end

local function sync_buffer_state(view)
  if
    not valid(view)
    or not phase.selected(view)
    or not view.comparison
    or vim.api.nvim_win_get_buf(view.right_win) ~= view.right_buf
  then
    return
  end
  local entry = view.selected_path and view.by_path[view.selected_path]
  if not entry then
    return
  end
  local buf = view.right_buf
  local dirty = view.comparison.right == "worktree" and buf ~= view.empty_buf and vim.bo[buf].modified
  view.file_missing = entry.status == "missing" and not dirty
  view.disk_conflict = dirty and (entry.right.kind ~= "text" or buffer_hash(buf) ~= entry.right.content_id) or false
  local path = header_path(view.selected_path)
  local left_revision = ui.endpoint(view.ui_icons, view.comparison.left)
  if view.follow_head then
    left_revision = ui.label(
      view.ui_icons,
      view.comparison.left == "" and "empty" or "commit",
      "HEAD · " .. (view.comparison.left == "" and "Empty tree" or view.comparison.left:sub(1, 8))
    )
  end
  if view.file_missing then
    header(
      view,
      view.left_win,
      path
        .. "%#DiffreelDiffWinbarState# · "
        .. ui.winbar(ui.label(view.ui_icons, "warning", "File is absent from both endpoints"))
        .. "%*"
    )
  else
    header(
      view,
      view.left_win,
      entry.old_path and header_path(entry.old_path) or path,
      "%#DiffreelDiffWinbarRevision# " .. ui.winbar(left_revision) .. " %*"
    )
  end
  local detail = dirty
      and format_label({
        fileformat = vim.bo[buf].fileformat,
        bom = vim.bo[buf].bomb,
        endofline = vim.bo[buf].endofline,
      })
    or format_label(entry.right)
  local right_revision = ui.endpoint(view.ui_icons, view.comparison.right)
  if dirty then
    right_revision = ui.label(view.ui_icons, "unsaved", "Unsaved")
  end
  if view.layout == "inline" then
    local reason = entry.left.reason or entry.right.reason
    if reason then
      right_revision = right_revision
        .. " · "
        .. ui.label(view.ui_icons, "warning", "Not compared: " .. explorer.display(reason))
    end
    if view.file_missing then
      right_revision = ui.label(view.ui_icons, "warning", "File is absent from both endpoints")
    end
  end
  header(
    view,
    view.right_win,
    path,
    "%#"
      .. (dirty and "DiffreelDiffWinbarModified" or "DiffreelDiffWinbarRevision")
      .. "# "
      .. ui.winbar(right_revision)
      .. "%*"
      .. ((detail == "LF" or detail == "") and "" or ("%#DiffreelDiffWinbarState# · " .. detail:gsub("%%", "%%%%")))
      .. " %*"
  )
end

M.render, M.loading, M.sync_buffer_state = render, loading, sync_buffer_state

return M
