local channel = ...
local probe = { count = 0, calls = {} }
_G.diffreel_probe = probe
local spawn = vim.uv.spawn
vim.uv.spawn = function(command, opts, callback)
  if vim.fs.basename(command) == "git" then
    probe.count = probe.count + 1
    probe.calls[#probe.calls + 1] = { at = vim.uv.hrtime(), args = opts.args }
  end
  return spawn(command, opts, callback)
end
for _, method in ipairs({ "system", "systemlist", "jobstart" }) do
  local original = vim.fn[method]
  vim.fn[method] = function(command, ...)
    local executable = type(command) == "table" and command[1] or command:match("^%s*(%S+)")
    if executable and vim.fs.basename(executable) == "git" then
      probe.count = probe.count + 1
      probe.calls[#probe.calls + 1] = { at = vim.uv.hrtime(), api = method, args = command }
    end
    return original(command, ...)
  end
end
local function buffer_hash(buf)
  local newline = vim.bo[buf].fileformat == "dos" and "\r\n" or "\n"
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), newline)
  if vim.bo[buf].endofline then
    text = text .. newline
  end
  if vim.bo[buf].bomb then
    text = string.char(239, 187, 191) .. text
  end
  return vim.fn.sha256(text)
end

function probe.explorer_matches(view)
  local lines = vim.api.nvim_buf_get_lines(view.explorer_buf, 0, -1, false)
  local expected_stats = _G.diffreel_expected_line_stats
  if expected_stats then
    local stats = view.statistics
    if
      not view.line_stats
      or not stats
      or not stats.complete
      or stats.pending
      or stats.error
      or stats.generation ~= view.comparison.generation
      or stats.unavailable ~= 0
      or stats.additions ~= expected_stats.additions
      or stats.deletions ~= expected_stats.deletions
      or not vim.deep_equal(stats.files, expected_stats.files)
      or lines[#view.rows + 5] ~= "Saved lines: +" .. expected_stats.additions .. " -" .. expected_stats.deletions
    then
      return false
    end
  end
  if
    view.error
    or view.navigation
    or view.updating
    or #lines ~= #view.rows + 4 + (view.disk_conflict and 1 or 0) + (expected_stats and 1 or 0)
  then
    return false
  end
  for i, line in ipairs(_G.diffreel_expected_explorer_headers or {}) do
    if lines[i] ~= line then
      return false
    end
  end
  local marks = vim.api.nvim_buf_get_extmarks(
    view.explorer_buf,
    vim.api.nvim_create_namespace("diffreel"),
    0,
    -1,
    { details = true }
  )
  local selected, styles, count = {}, {}, 2
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.line_hl_group == "DiffreelExplorerSelected" then
      selected[#selected + 1] = mark[2] + 1
    end
    if details.hl_group then
      styles[mark[2] .. ":" .. mark[3]] = details.hl_group
    end
  end
  local selected_row
  for i, row in ipairs(view.rows) do
    if lines[i + 3] ~= row.text then
      return false
    end
    count = count + #row.highlights
    for _, span in ipairs(row.highlights) do
      local expected = span.icon and require("diffreel.highlights").icon(span.group, row.icon_group) or span.group
      if styles[(i + 2) .. ":" .. span.first] ~= expected then
        return false
      end
    end
    if row.entry then
      local entry = view.by_path[row.path]
      if not entry or row.entry.status ~= entry.status or row.entry.buffer_only ~= entry.buffer_only then
        return false
      end
      if expected_stats then
        local value = expected_stats.files[row.path]
        if not value or not row.text:find("+" .. value.additions .. " -" .. value.deletions .. " ", 1, true) then
          return false
        end
      end
      if row.path == view.selected_path then
        selected_row = i + 3
        count = count + 1
      end
    end
  end
  count = count + #(view.explorer_render and view.explorer_render.details or {})
  if #marks ~= count or #selected ~= (selected_row and 1 or 0) or selected[1] ~= selected_row then
    return false
  end
  if view.disk_conflict and not view.error then
    return lines[#lines] == "Unsaved buffer differs from disk"
  end
  return lines[#lines] ~= "Unsaved buffer differs from disk"
end

function probe.matches(view)
  if view.selected_path ~= _G.diffreel_expected_path then
    return false
  end
  if
    vim.api.nvim_win_get_buf(view.left_win) ~= view.left_buf
    or vim.api.nvim_win_get_buf(view.right_win) ~= view.right_buf
    or not vim.wo[view.left_win].diff
    or not vim.wo[view.right_win].diff
  then
    return false
  end
  local left, right = buffer_hash(view.left_buf), buffer_hash(view.right_buf)
  if not _G.diffreel_expected_left_hashes or left ~= _G.diffreel_expected_left_hashes[view.selected_path] then
    return false
  end
  if
    not _G.diffreel_expected_hashes
    or right ~= (_G.diffreel_expected_buffer_hash or _G.diffreel_expected_hashes[view.selected_path])
  then
    return false
  end
  for path, hash in pairs(_G.diffreel_expected_hashes) do
    if not view.by_path[path] or view.by_path[path].right.content_id ~= hash then
      return false
    end
  end
  if _G.diffreel_expected_unchanged_line then
    for _, win in ipairs({ view.left_win, view.right_win }) do
      local highlight = vim.api.nvim_win_call(win, function()
        return vim.fn.diff_hlID(_G.diffreel_expected_unchanged_line, 1)
      end)
      if highlight ~= 0 then
        return false
      end
    end
  end
  if _G.diffreel_verify_explorer and not probe.explorer_matches(view) then
    return false
  end
  return true, left, right
end

vim.api.nvim_create_autocmd("User", {
  pattern = "DiffreelReady",
  callback = function(event)
    local view = _G.view
    if not view or not _G.diffreel_token or view.id ~= event.data.view_id then
      return
    end
    local matches, left, right = probe.matches(view)
    if not matches then
      return
    end
    vim.rpcnotify(
      channel,
      "diffreel_bench_ready",
      _G.diffreel_token,
      vim.tbl_extend("force", event.data, { left_hash = left, right_hash = right })
    )
  end,
})

return probe
