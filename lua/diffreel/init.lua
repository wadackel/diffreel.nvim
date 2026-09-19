local explorer = require("diffreel.explorer")
local lease = require("diffreel.lease")
local keymaps = require("diffreel.keymaps")
local presentation = require("diffreel.presentation")
local highlights = require("diffreel.highlights")
local install = require("diffreel.install")
local options = require("diffreel.options")
local spinner = require("diffreel.spinner")
local completion = require("diffreel.completion")
local help = require("diffreel.help")
local line_stats = require("diffreel.line_stats")
local panel = require("diffreel.panel")
local popup = require("diffreel.popup")
local full_name = require("diffreel.full_name")
local hunks = require("diffreel.hunks")
local pr = require("diffreel.pr")
local layout = require("diffreel.layout")
local windows = require("diffreel.windows")
local lifetime = require("diffreel.lifetime")
local phase = require("diffreel.phase")
local inline = require("diffreel.inline")
local ui = require("diffreel.ui")
local events = require("diffreel.events")
local buffers = require("diffreel.buffers")
local render_module = require("diffreel.render")
local manager = require("diffreel.manager")
local M = { views = {}, managers = {}, config = { backend = "rust", watch = true, auto_install = true }, sequence = 0 }
local active_keymaps
local continue_hunk
local shutting_down = false
local rebuild_inline
local valid = lifetime.valid
local emit, enter, leave = events.emit, events.enter, events.leave
local with_buffer_operation, owned_buffer, set_lines, put_virtual =
  buffers.with_operation, buffers.owned_buffer, buffers.set_lines, buffers.put_virtual
local release_right, buffer_hash, set_review_buffer, set_right_buffer =
  buffers.release_right, buffers.buffer_hash, buffers.set_review_buffer, buffers.set_right_buffer
local render, loading, sync_buffer_state = render_module.render, render_module.loading, render_module.sync_buffer_state

function M.get_view(id)
  local view = M.views[id]
  return view and view.alive and view or nil
end

local function current_tab_view()
  local tab = vim.api.nvim_get_current_tabpage()
  for _, view in pairs(M.views) do
    if view.tab == tab and valid(view) then
      return view
    end
  end
end

local function command_complete(lead, command, position)
  local view = current_tab_view()
  return completion.complete(lead, command, position, view and view.root)
end

-- A raised error would show a Lua traceback for a mistyped argument; echoing it as an error
-- still fails the command for callers such as pcall(vim.cmd, ...).
local function user_command(name, callback, opts)
  vim.api.nvim_create_user_command(name, function(args)
    local message
    local ok, err = xpcall(function()
      callback(args)
    end, function(raised)
      message = type(raised) == "string"
          and (raised:match("^diffreel: .*") or raised:match("^[^\n]-:%d+: (diffreel: .*)"))
        or nil
      return message or debug.traceback(raised, 2)
    end)
    if ok then
      return
    elseif message then
      vim.api.nvim_echo({ { message } }, true, { err = true })
    else
      error(err, 0)
    end
  end, opts)
end

function M.get_current()
  local win = vim.api.nvim_get_current_win()
  for _, view in pairs(M.views) do
    if valid(view) and windows.visible_pane(view, win) then
      return view
    end
  end
end

local function animate()
  local pending = false
  for _, view in pairs(M.views) do
    if loading(view) then
      -- A hidden view skips the redraw but still keeps the timer alive; stopping here
      -- would leave its glyph frozen at whatever frame was current when the tab left.
      pending = true
      if vim.api.nvim_get_current_tabpage() == view.tab then
        pcall(render, view, nil, true)
      end
    end
  end
  return pending
end

spinner.register(animate)

local function actions(scope)
  return keymaps.bindings(active_keymaps[scope], M, render)
end

local function mode_bindings()
  local modes = {}
  for _, scope in ipairs({ "diff_visual", "diff_operator" }) do
    local bindings, alternates = actions(scope)
    modes[keymaps.scopes[scope]] =
      { actions = bindings, alternates = alternates, guards = keymaps.guards(active_keymaps[scope]) }
  end
  return modes
end

local function current_buffer_view(buf)
  local view = M.get_current()
  if
    view
    and not view.navigation
    and view.right_win == vim.api.nvim_get_current_win()
    and view.right_buf == buf
    and vim.api.nvim_get_current_buf() == buf
  then
    return view
  end
end

local function ready(view)
  if valid(view) and phase.settled(view) then
    if view.requested_layout and view.requested_layout ~= view.layout then
      M.set_layout(view, view.requested_layout)
      return
    end
    if view.layout_pending or view.inline_pending then
      return
    end
    if view.layout == "inline" and not inline.current(view) then
      rebuild_inline(view)
      return
    end
    local sequence = view.selection_seq
    emit(view, "Ready")
    if not valid(view) or not view.ready or view.selection_seq ~= sequence then
      return
    end
    if continue_hunk then
      continue_hunk(view)
    end
    if not valid(view) or not phase.selected(view) then
      return
    end
    line_stats.start(view, render)
  end
end

local changed_buffers, state_queued = {}, false
local function buffer_changed(buf)
  if not lease.buffers[buf] then
    return
  end
  changed_buffers[buf] = true
  if state_queued then
    return
  end
  state_queued = true
  vim.schedule(function()
    local changed = changed_buffers
    changed_buffers, state_queued = {}, false
    for _, view in pairs(M.views) do
      if valid(view) and changed[view.right_buf] then
        sync_buffer_state(view)
        render(view)
        if view.layout == "inline" then
          rebuild_inline(view)
        end
      end
    end
  end)
end

local function select(view, path, reveal, prepared)
  if not valid(view) or not view.comparison or view.switching then
    return
  end
  local entry = view.by_path[path]
  if not entry then
    return
  end
  if view.layout == "inline" then
    inline.clear(view)
  end
  view.initial_selection_done = true
  view.deferred_path = nil
  view.selection_seq = view.selection_seq + 1
  local ticket = lifetime.ticket(view, "selection")
  local comparison_id = ticket.comparison_id
  local expected_buffer = vim.api.nvim_win_get_buf(view.right_win)
  if reveal then
    view.reveal_path = path
    explorer.reveal(view.collapsed, path)
  end
  view.selected_path = path
  phase.enter(view, "selecting")
  local left, right
  local function current()
    return lifetime.current(view, ticket)
      and not view.closing
      and not view.switching
      and vim.api.nvim_win_get_buf(view.right_win) == expected_buffer
  end
  local function fail(error)
    if current() then
      phase.enter(view, "failed", tostring(error))
      view.pending_hunk = nil
      render(view)
    end
  end
  local function apply_buffers()
    local previous = view.right_buf
    local plain = entry.status ~= "typechange" and entry.left.kind ~= "limited" and entry.right.kind ~= "limited"
    local full = view.manager.root .. "/" .. path
    local dirty
    if view.comparison.right == "worktree" then
      for _, info in ipairs(vim.fn.getbufinfo({ bufloaded = 1, bufmodified = 1 })) do
        if info.name == full then
          dirty = info.bufnr
          break
        end
      end
    end
    local buf
    if dirty or (plain and view.comparison.right == "worktree" and right.exists and right.kind == "text") then
      local stat = vim.uv.fs_lstat(full)
      if not dirty and (not stat or stat.type ~= "file") then
        view.updating = true
        M.refresh(view)
        return
      end
      buf = dirty or vim.fn.bufadd(full)
      local bindings, alternates = actions("diff")
      lease.acquire(buf, view.id, function()
        return current_buffer_view(buf)
      end, bindings, alternates, mode_bindings(), keymaps.conditions(active_keymaps.diff))
      local was_loaded = vim.api.nvim_buf_is_loaded(buf)
      local loaded, load_error = true, nil
      if not was_loaded then
        loaded, load_error = pcall(vim.fn.bufload, buf)
      end
      if not loaded or not vim.api.nvim_buf_is_valid(buf) then
        if buf ~= previous then
          lease.release(buf, view.id)
        end
        if not was_loaded and vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
          pcall(vim.api.nvim_buf_delete, buf, { unload = true })
        end
        fail(load_error or "diffreel: working-tree buffer was removed while loading")
        return
      end
      if not current() then
        if buf ~= previous then
          lease.release(buf, view.id)
        end
        return
      end
      buffers.observe(buf, buffer_changed)
      put_virtual(view, "left", left, path)
      set_review_buffer(view, view.left_win, view.left_buf)
      expected_buffer = buf
      set_right_buffer(view, buf)
      if was_loaded and vim.bo[buf].modified then
        view.disk_conflict = right.kind ~= "text" or buffer_hash(buf) ~= right.content_id
      else
        view.disk_conflict = false
        vim.api.nvim_win_call(view.right_win, function()
          if vim.api.nvim_get_current_buf() == buf and not vim.bo[buf].modified then
            vim.cmd("checktime " .. buf)
          end
        end)
      end
    else
      if not plain then
        left = {
          kind = "limited",
          reason = entry.left.reason or entry.right.reason or entry.status,
          mode = entry.left.mode,
          size = entry.left.size,
          oid = entry.left.oid,
        }
        right = {
          kind = "limited",
          reason = entry.right.reason or entry.left.reason or entry.status,
          mode = entry.right.mode,
          size = entry.right.size,
          oid = entry.right.oid,
        }
      end
      put_virtual(view, "left", left, path)
      set_review_buffer(view, view.left_win, view.left_buf)
      buf = put_virtual(view, "right", right, path)
      expected_buffer = buf
      set_right_buffer(view, buf)
      view.disk_conflict = false
    end
    view.right_buf = buf
    release_right(view, previous)
    for _, win in ipairs(windows.engine_windows(view)) do
      if not current() then
        return
      end
      vim.api.nvim_win_call(win, function()
        if plain then
          local restarted = not vim.wo[win].diff
          if restarted then
            presentation.diffthis(view, win)
          end
          if view.layout == "inline" then
            presentation.engine(view, win)
          else
            presentation.apply(view, win, restarted)
          end
        else
          presentation.diffoff(view, win)
          presentation.restore(view, win)
        end
      end)
    end
    if view.layout == "inline" then
      vim.api.nvim_win_call(view.right_win, function()
        presentation.diffoff(view, view.right_win)
      end)
      presentation.inline(view, view.right_win)
    end
    -- Native diff does not resynchronize diverged views until a pane scrolls: the reused left buffer keeps
    -- the previous file's view while the right buffer restores its own. Resetting on every reapplication
    -- would instead jump to the top on each edit or refresh of the same file.
    if view.positioned_path ~= path then
      view.positioned_path, view.saved_left_view = path, nil
      for _, win in ipairs({ view.left_win, view.right_win, view.right_engine }) do
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview({ lnum = 1, col = 0, topline = 1, topfill = 0, leftcol = 0 })
        end)
      end
    end
    vim.schedule(function()
      if not current() then
        return
      end
      if
        buf ~= view.empty_buf
        and not vim.bo[buf].modified
        and right.content_id
        and buffer_hash(buf) ~= right.content_id
      then
        local stat = vim.uv.fs_lstat(view.manager.root .. "/" .. path)
        if stat and stat.type == "file" then
          local ok, err = pcall(with_buffer_operation, function()
            vim.api.nvim_win_call(view.right_win, function()
              if current() and vim.api.nvim_get_current_buf() == buf and not vim.bo[buf].modified then
                vim.cmd("edit!")
              end
            end)
          end)
          if not ok then
            fail(err)
            return
          end
        end
      end
      if not current() then
        return
      end
      if plain then
        pcall(vim.api.nvim_win_call, windows.engine(view, view.right_win), function()
          vim.cmd("diffupdate")
        end)
      end
      phase.enter(view, "ready")
      sync_buffer_state(view)
      render(view)
      for _, side in ipairs({ "left", "right" }) do
        local visible = side == "right" or view.layout ~= "inline"
        emit(view, "DiffBufRead", {
          bufnr = view[side .. "_buf"],
          winid = visible and view[side .. "_win"] or nil,
          side = side,
          visible = visible,
          layout = view.layout,
        })
        if not current() then
          return
        end
      end
      if view.event_path ~= path or view.event_comparison ~= comparison_id then
        local previous_path = view.event_path
        view.event_path, view.event_comparison = path, comparison_id
        emit(view, "FileSelect", { previous_path = previous_path })
        if not current() then
          return
        end
      end
      ready(view)
    end)
    view.manager.backend:request("view/update", {
      view_id = view.id,
      comparison_id = comparison_id,
      visible = vim.api.nvim_get_current_tabpage() == view.tab,
      path = path,
    }, function(err)
      if err then
        fail(err)
      end
    end)
  end
  local function apply()
    if not current() or not left or not right then
      return
    end
    if view.layout_changing then
      vim.schedule(apply)
      return
    end
    with_buffer_operation(apply_buffers)
  end
  local function read(side, callback)
    local metadata = entry[side]
    if metadata.kind == "missing" then
      callback({ exists = false, kind = "missing", lines = { "" }, endofline = false, mode = "000000", size = 0 })
    elseif metadata.kind == "limited" then
      callback(metadata)
    elseif side == "right" and view.comparison.right == "worktree" then
      if metadata.kind == "symlink" then
        local target, err = vim.uv.fs_readlink(view.manager.root .. "/" .. path)
        if not target then
          fail(err)
          return
        end
        callback(require("diffreel.content").decode(target, "120000", M.config.max_bytes))
      else
        callback(metadata)
      end
    else
      view.manager.backend:request("blob/read", { oid = metadata.oid, mode = metadata.mode }, function(err, value)
        if not current() then
          return
        end
        if err then
          fail(err)
        else
          callback(value)
        end
      end)
    end
  end
  local function load()
    if prepared and prepared.path == path then
      left, right = prepared.left, prepared.right
      apply()
      return
    end
    read("left", function(value)
      left = value
      apply()
    end)
    read("right", function(value)
      right = value
      apply()
    end)
  end
  if entry.buffer_only then
    -- A vanished Git entry cannot supply the current HEAD or disk content for a retained draft.
    view.manager.backend:request("comparison/file", { comparison_id = comparison_id, path = path }, function(err, value)
      if not current() then
        return
      end
      if err then
        fail(err)
        return
      end
      entry = value
      entry.buffer_only = true
      view.by_path[path] = entry
      for i, row in ipairs(view.entries) do
        if row.path == path then
          view.entries[i] = entry
          break
        end
      end
      view.tree = explorer.build(view.entries)
      load()
    end)
  else
    load()
  end
  render(view)
end

function M.select(view, path)
  if view and view.pr_recovery then
    return
  end
  if view then
    view.pending_hunk = nil
    if view.pr_request and view.comparison then
      pr.cancel(view)
      view.updating = false
    end
    if view.switching and view.by_path and view.by_path[path] then
      view.deferred_path, view.reveal_path = path, path
      explorer.reveal(view.collapsed, path)
      render(view)
      return
    end
  end
  return select(view, path, true)
end

local function receive(view, snapshot, prepared)
  if not valid(view) or view.switching then
    return
  end
  if view.layout_changing then
    vim.schedule(function()
      receive(view, snapshot, prepared)
    end)
    return
  end
  if view.comparison and snapshot.generation < view.comparison.generation then
    return
  end
  if
    view.comparison
    and snapshot.comparison_id == view.comparison.comparison_id
    and snapshot.generation == view.comparison.generation
    and snapshot.updating == view.comparison.updating
    and snapshot.error == view.comparison.error
    and snapshot.updating == view.updating
    and snapshot.error == view.error
    and phase.has_content(view)
  then
    return
  end
  local previous = view.selected_path and view.by_path[view.selected_path]
  view.comparison, view.updating, view.error = snapshot, snapshot.updating, snapshot.error
  view.entries, view.by_path = vim.deepcopy(snapshot.entries), {}
  for _, entry in ipairs(view.entries) do
    view.by_path[entry.path] = entry
  end
  if
    previous
    and not view.by_path[previous.path]
    and snapshot.right == "worktree"
    and view.right_buf
    and view.right_buf ~= view.empty_buf
    and vim.api.nvim_buf_is_valid(view.right_buf)
    and vim.bo[view.right_buf].modified
  then
    previous = vim.deepcopy(previous)
    previous.buffer_only = true
    view.entries[#view.entries + 1] = previous
    view.by_path[previous.path] = previous
  end
  view.tree = explorer.build(view.entries)
  view.entries = explorer.ordered(view.tree, view.explorer_options.mode)
  if view.right_buf and vim.api.nvim_win_get_buf(view.right_win) ~= view.right_buf then
    phase.enter(view, "paused")
    render(view)
    return
  end
  local selected = view.selected_path and view.by_path[view.selected_path]
  if not view.initial_selection_done then
    view.initial_selection_done = true
    selected = view.preferred_path and view.by_path[view.preferred_path] or selected
  end
  local deferred = view.deferred_path
  view.deferred_path = nil
  if deferred and view.by_path[deferred] then
    selected = view.by_path[deferred]
  end
  if not selected then
    selected = view.entries[1]
  end
  if
    selected
    and (selected.buffer_only or not previous or not vim.deep_equal(previous, selected) or not phase.has_content(view))
  then
    select(view, selected.path, false, prepared)
  elseif not selected then
    view.selection_seq = view.selection_seq + 1
    view.selected_path = nil
    phase.enter(view, "empty")
    view.positioned_path = nil
    view.disk_conflict = false
    local previous_buf = view.right_buf
    view.right_buf = view.empty_buf
    set_right_buffer(view, view.empty_buf)
    for _, win in ipairs(windows.engine_windows(view)) do
      vim.api.nvim_win_call(win, function()
        presentation.diffoff(view, win)
      end)
      presentation.restore(view, win)
    end
    release_right(view, previous_buf)
    set_lines(view.left_buf, { "" })
    set_lines(view.empty_buf, { "" })
    if view.event_path ~= nil then
      local previous_path = view.event_path
      view.event_path, view.event_comparison = nil, snapshot.comparison_id
      emit(view, "FileSelect", { previous_path = previous_path })
      if not valid(view) or view.selected_path ~= nil then
        return
      end
    end
  end
  sync_buffer_state(view)
  render(view)
  ready(view)
end

local function open_comparison(view)
  if not valid(view) then
    return
  end
  view.compare_seq = view.compare_seq + 1
  view.pending_hunk = nil
  local ticket = lifetime.ticket(view, "comparison")
  phase.enter(view, "switching")
  render(view)
  local spec = view.resolved_spec or view.spec
  view.manager.backend:request("comparison/open", {
    left = spec.left,
    right = spec.right,
    paths = spec.paths,
    untracked = spec.untracked,
    merge_base = spec.merge_base,
    file = spec.file,
    view_id = view.id,
  }, function(err, snapshot)
    if not lifetime.current(view, ticket) then
      return
    end
    phase.enter(view, "answered")
    if err then
      view.deferred_path = nil
      phase.enter(view, "stopped", tostring(err))
      render(view)
      return
    end
    view.comparison = nil
    view.resolved_spec = {
      left = view.follow_head and "HEAD" or snapshot.left,
      right = snapshot.right,
      paths = vim.deepcopy(view.spec.paths),
      untracked = view.spec.untracked,
      file = view.spec.file,
    }
    view.selection_seq = view.selection_seq + 1
    phase.enter(view, "received")
    view.manager.backend:request("view/update", {
      view_id = view.id,
      comparison_id = snapshot.comparison_id,
      visible = vim.api.nvim_get_current_tabpage() == view.tab,
    }, function() end)
    receive(view, snapshot)
  end)
end

local function activate_pr(view, snapshot, metadata, prepared)
  if not valid(view) then
    return
  end
  view.compare_seq, view.selection_seq = view.compare_seq + 1, view.selection_seq + 1
  view.pr = metadata
  view.spec.left, view.spec.right = metadata.merge_base, metadata.head
  view.resolved_spec = vim.deepcopy(view.spec)
  view.comparison = nil
  phase.enter(view, "received")
  view.selected_path, view.deferred_path = prepared and prepared.path or nil, nil
  receive(view, snapshot, prepared)
end

local function notify(manager, method, params)
  for _, view in pairs(M.views) do
    if view.manager == manager and valid(view) then
      if method == "pr/prepared" or method == "pr/error" then
        pr.notify(view, method, params)
      elseif method == "repo/changed" and view.follow_head then
        open_comparison(view)
      elseif
        method == "comparison/updated"
        and view.comparison
        and params.comparison_id == view.comparison.comparison_id
        and not view.pr_request
      then
        receive(view, params)
      elseif
        method == "comparison/progress"
        and view.comparison
        and params.comparison_id == view.comparison.comparison_id
        and not view.pr_request
      then
        view.updating = true
        render(view)
      elseif method == "backend/error" then
        pr.cancel(view)
        phase.enter(view, "stopped", params.message)
        render(view)
      end
    end
  end
end

function M.open(opts)
  assert(not shutting_down, "diffreel: cannot open a review during shutdown")
  opts = options.normalize(opts == nil and {} or opts, M.config)
  if opts.layout == "inline" then
    local ok, reason = inline.check()
    assert(ok, "diffreel: " .. tostring(reason))
  end
  if opts.pr then
    assert(vim.fn.executable("gh") == 1, "diffreel: PR review requires GitHub CLI (gh)")
  end
  local invoking_file = vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) or nil
  local current = current_tab_view()
  local requested_file = opts.file or nil
  if requested_file == true then
    requested_file = invoking_file and invoking_file ~= "" and invoking_file or (current and current.selected_path)
    assert(requested_file, "diffreel: --file requires a named file or an active selection")
  end
  active_keymaps = active_keymaps or keymaps.resolve(M.config.keymaps)
  local root = opts.root
  if not root then
    root = requested_file and requested_file:sub(1, 1) == "/" and vim.fs.root(requested_file, { ".git" })
      or (current and current.root)
      or vim.fs.root(vim.api.nvim_buf_get_name(0), { ".git" })
      or vim.fs.root(vim.fn.getcwd(), { ".git" })
  end
  assert(root, "diffreel: current file is not in a Git repository")
  root = vim.fs.root(root, { ".git" }) or root
  local pinned_path = requested_file and options.preferred_path(root, nil, requested_file)
  root = assert(vim.uv.fs_realpath(root))
  root = vim.fs.root(root, { ".git" }) or root
  if requested_file then
    pinned_path = pinned_path or options.preferred_path(root, nil, requested_file)
    assert(pinned_path and pinned_path ~= "", "diffreel: file must be inside the repository")
  end
  local default_explorer_width = M.config.width
  local ui_icons = ui.resolve(M.config.ui_icons)
  local initial_sizing = panel.prepare(
    { explorer_options = opts.explorer, default_explorer_width = default_explorer_width },
    opts.explorer,
    opts.explorer
  )
  M.sequence = M.sequence + 1
  local id = "view-" .. M.sequence
  local return_tab = vim.api.nvim_get_current_tabpage()
  local return_options = current and current.return_options
    or presentation.capture_window(vim.api.nvim_get_current_win())
  local allocated, existing, tabs = {}, vim.api.nvim_list_bufs(), vim.api.nvim_list_tabpages()
  local tab, right, initial, left, left_buf, empty_buf, panel_buf
  local created, creation_error = pcall(function()
    vim.cmd("tabnew")
    tab, right = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
    initial = vim.api.nvim_get_current_buf()
    left_buf = owned_buffer("diffreel://" .. id .. "/left", allocated)
    empty_buf = owned_buffer("diffreel://" .. id .. "/right", allocated)
    panel_buf = owned_buffer("diffreel://" .. id .. "/files", allocated)
    vim.api.nvim_win_set_buf(right, empty_buf)
    left = vim.api.nvim_open_win(left_buf, true, { split = "left", win = right })
  end)
  if not created then
    if not tab then
      local added = vim.tbl_filter(function(candidate)
        return not vim.tbl_contains(tabs, candidate)
      end, vim.api.nvim_list_tabpages())
      if #added == 1 then
        tab = added[1]
        initial = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))
      end
    end
    if tab and vim.api.nvim_tabpage_is_valid(tab) then
      pcall(function()
        vim.api.nvim_set_current_tabpage(tab)
        vim.cmd("tabclose")
      end)
    end
    for _, buf in ipairs(allocated) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    if vim.api.nvim_tabpage_is_valid(return_tab) then
      vim.api.nvim_set_current_tabpage(return_tab)
    end
  end
  if
    initial
    and not vim.tbl_contains(existing, initial)
    and vim.api.nvim_buf_is_valid(initial)
    and vim.api.nvim_buf_get_name(initial) == ""
  then
    pcall(vim.api.nvim_buf_delete, initial, { force = false })
  end
  if not created then
    error(creation_error, 0)
  end
  vim.bo[panel_buf].filetype = "diffreel"
  local view = {
    id = id,
    tab = tab,
    return_tab = return_tab,
    return_options = return_options,
    explorer_options = opts.explorer,
    ui_icons = ui_icons,
    default_explorer_width = default_explorer_width,
    left_win = left,
    right_win = right,
    explorer_buf = panel_buf,
    left_buf = left_buf,
    empty_buf = empty_buf,
    right_buf = empty_buf,
    root = root,
    layout = "side_by_side",
    pr_target = opts.pr,
    spec = {
      left = opts.left,
      right = opts.right,
      paths = opts.paths,
      untracked = opts.untracked,
      merge_base = opts.merge_base,
      file = pinned_path,
    },
    preferred_path = pinned_path or options.preferred_path(root, invoking_file, opts.selected_file),
    pinned_path = pinned_path,
    line_stats = opts.line_stats,
    alive = true,
    updating = true,
    entries = {},
    by_path = {},
    collapsed = {},
    selection_seq = 0,
    compare_seq = 0,
    keymap_callbacks = {},
  }
  view.follow_head = not view.spec.merge_base
    and view.spec.left == "HEAD"
    and (view.spec.right == "worktree" or view.spec.right == ":0")
  M.views[id] = view
  local laid_out, layout_error = pcall(panel.apply, view, opts.explorer, opts.explorer, initial_sizing)
  if not laid_out then
    M.close(view)
    error(layout_error, 0)
  end
  if opts.layout ~= "side_by_side" then
    local changed, change_error = pcall(layout.apply, view, opts.layout)
    if not changed then
      M.close(view)
      error(change_error, 0)
    end
  end
  vim.api.nvim_win_set_width(
    left,
    math.max(1, math.floor((vim.api.nvim_win_get_width(left) + vim.api.nvim_win_get_width(right)) / 2))
  )
  layout.capture_ratio(view)
  vim.api.nvim_set_current_win(view.explorer_win or view.right_win)
  local bindings = actions("explorer")
  view.keymap_callbacks[panel_buf] = {}
  for _, binding in ipairs(active_keymaps.explorer) do
    local action = bindings[binding.lhs]
    local callback = function()
      if M.get_current() == view and vim.api.nvim_get_current_win() == view.explorer_win then
        action(view, vim.v.count1)
      end
    end
    vim.keymap.set("n", binding.lhs, callback, { buffer = panel_buf, silent = true })
    view.keymap_callbacks[panel_buf][binding.lhs] = callback
  end
  for _, buf in ipairs({ left_buf, empty_buf }) do
    local maps, alternates = actions("diff")
    lease.acquire(buf, view.id, function()
      if M.get_current() == view and (vim.api.nvim_get_current_win() == view.left_win or current_buffer_view(buf)) then
        return view
      end
    end, maps, alternates, mode_bindings(), keymaps.conditions(active_keymaps.diff))
  end
  render(view)
  view.opened = true
  emit(view, "Open", { explorer = vim.deepcopy(view.explorer_options), layout = view.layout })
  if not valid(view) then
    return view
  end
  enter(view)
  if not valid(view) then
    return view
  end
  manager.get(M, view, notify, function(err, manager)
    if not valid(view) then
      return
    end
    if err then
      phase.enter(view, "stopped", tostring(err))
      render(view)
    else
      view.manager = manager
      if view.pr_target then
        pr.start(view, render, activate_pr)
      else
        open_comparison(view)
      end
    end
  end)
  return view
end

local function apply_explorer(view, next_options, settings, automatic)
  local previous = view.explorer_options
  view.explorer_update_seq = (view.explorer_update_seq or 0) + 1
  local sequence = view.explorer_update_seq
  local sizing = panel.prepare(view, next_options, settings, automatic)
  if not valid(view) or view.explorer_options ~= previous or view.explorer_update_seq ~= sequence then
    return
  end
  if automatic and not sizing then
    return
  end
  local width = windows.explorer_visible(view) and vim.api.nvim_win_get_width(view.explorer_win)
  local height = windows.explorer_visible(view) and vim.api.nvim_win_get_height(view.explorer_win)
  full_name.close(view)
  if not automatic then
    popup.close(view, "path_popup")
    help.close(view)
  end
  if next_options.visible then
    view.explorer_refocus = nil
  end
  panel.apply(view, next_options, settings, sizing)
  if not valid(view) then
    return
  end
  if view.tree then
    view.entries = explorer.ordered(view.tree, next_options.mode)
  end
  render(view)
  if view.layout == "inline" and not view.inline_pending then
    rebuild_inline(view)
  end
  local changed = not vim.deep_equal(previous, view.explorer_options)
    or width ~= (windows.explorer_visible(view) and vim.api.nvim_win_get_width(view.explorer_win))
    or height ~= (windows.explorer_visible(view) and vim.api.nvim_win_get_height(view.explorer_win))
  if changed and not automatic then
    emit(view, "LayoutChanged", { explorer = vim.deepcopy(view.explorer_options), layout = view.layout })
  end
end

function M.set_explorer(view, settings)
  view = view or current_tab_view()
  if not view or not valid(view) then
    return
  end
  local next_options = options.explorer(settings, view.explorer_options)
  if vim.deep_equal(next_options, view.explorer_options) and not settings.width and not settings.height then
    return
  end
  apply_explorer(view, next_options, settings)
end

local function resize_explorer(view)
  if
    not valid(view)
    or not windows.explorer_visible(view)
    or vim.api.nvim_get_current_tabpage() ~= view.tab
    or view.layout_changing
  then
    return
  end
  local axis = panel.axis(view.explorer_options)
  local pending, generation = panel.pending(view)
  if not pending or (view.explorer_size_errors or {})[axis] == generation then
    return
  end
  local sequence = (view.explorer_update_seq or 0) + 1
  local ok, err = pcall(apply_explorer, view, view.explorer_options, {}, true)
  if not ok and valid(view) and view.explorer_update_seq == sequence then
    view.explorer_size_errors = view.explorer_size_errors or {}
    local reported = view.explorer_size_errors[axis]
    view.explorer_size_errors[axis] = generation
    if not reported then
      vim.notify("diffreel: explorer." .. axis .. " resize failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function resize_view(view)
  resize_explorer(view)
  if
    valid(view)
    and view.layout_resize_pending
    and not view.layout_changing
    and vim.api.nvim_get_current_tabpage() == view.tab
  then
    local ok, err = pcall(layout.resize, view)
    if not ok then
      vim.notify("diffreel: diff pane resize failed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end
end

local function layout_event(view, previous)
  if not valid(view) then
    return
  end
  sync_buffer_state(view)
  render(view)
  emit(
    view,
    "LayoutChanged",
    { layout = view.layout, previous_layout = previous, explorer = vim.deepcopy(view.explorer_options) }
  )
end

function M.set_layout(view, mode)
  view = view or current_tab_view()
  assert(vim.tbl_contains({ "side_by_side", "stacked", "inline" }, mode), "diffreel: invalid layout")
  if not view or not valid(view) then
    return
  end
  if mode == "inline" then
    local ok, reason = inline.check(view)
    assert(ok, "diffreel: " .. tostring(reason))
  end
  if view.layout == mode and not view.layout_pending and not view.requested_layout then
    return
  end
  inline.clear(view)
  layout.clear_staging(view)
  view.pending_hunk, view.layout_pending, view.requested_layout = nil, nil, nil
  local previous = view.layout
  if mode == previous then
    return
  end
  if mode == "inline" and (not view.ready or view.navigation) then
    view.requested_layout = mode
    return
  end
  if mode ~= "inline" then
    local ok, err = pcall(layout.apply, view, mode)
    if not ok then
      if valid(view) and view.layout == "inline" then
        rebuild_inline(view)
      end
      error(err, 0)
    end
    layout_event(view, previous)
    return
  end
  local token = {}
  view.layout_pending = token
  local staged, engines = pcall(layout.staging, view)
  if not staged then
    view.layout_pending = nil
    error(engines, 0)
  end
  inline.compute(view, engines, function(err, cache, stale)
    if not valid(view) or view.layout_pending ~= token then
      return
    end
    view.layout_pending = nil
    if err then
      layout.clear_staging(view)
      if stale then
        if phase.selected(view) then
          M.set_layout(view, mode)
        else
          view.requested_layout = mode
        end
      else
        vim.notify("diffreel: " .. err, vim.log.levels.WARN)
      end
      return
    end
    local ok, failure = pcall(function()
      layout.apply(view, mode)
      inline.attach(view, cache)
    end)
    if not ok then
      inline.clear(view)
      pcall(layout.apply, view, previous)
      vim.notify("diffreel: " .. tostring(failure), vim.log.levels.ERROR)
      return
    end
    layout_event(view, previous)
    ready(view)
  end)
end

function M.cycle_layout(view)
  view = view or current_tab_view()
  if not view or not valid(view) then
    return
  end
  local modes = { side_by_side = "stacked", stacked = "inline", inline = "side_by_side" }
  return M.set_layout(view, modes[view.requested_layout or (view.layout_pending and "inline") or view.layout])
end

rebuild_inline = function(view)
  if not valid(view) or view.layout ~= "inline" or not phase.interactive(view) or view.layout_changing then
    return
  end
  inline.clear(view)
  inline.compute(view, windows.engine_windows(view), function(err, cache, stale)
    if not valid(view) or view.layout ~= "inline" then
      return
    end
    if stale then
      rebuild_inline(view)
      return
    end
    if err then
      M.set_layout(view, view.last_split or "side_by_side")
      vim.notify("diffreel: " .. err, vim.log.levels.WARN)
    else
      local ok, failure = pcall(inline.attach, view, cache)
      if not ok then
        M.set_layout(view, view.last_split or "side_by_side")
        vim.notify("diffreel: " .. tostring(failure), vim.log.levels.WARN)
      end
    end
    ready(view)
  end)
end

function M.toggle_explorer(view)
  view = view or current_tab_view()
  if not view or not valid(view) then
    return
  end
  if windows.explorer_visible(view) then
    local focused = vim.api.nvim_get_current_win() == view.explorer_win
    M.set_explorer(view, { visible = false })
    view.explorer_refocus = focused and not windows.explorer_visible(view) or nil
    return
  end
  local refocus = view.explorer_refocus
  M.set_explorer(view, { visible = true })
  if refocus and valid(view) and windows.explorer_visible(view) and vim.api.nvim_get_current_tabpage() == view.tab then
    vim.api.nvim_set_current_win(view.explorer_win)
  end
end

function M.focus_explorer(view)
  view = view or current_tab_view()
  if not view or not valid(view) then
    return
  end
  if not windows.explorer_visible(view) then
    M.set_explorer(view, { visible = true })
  end
  if valid(view) and windows.explorer_visible(view) then
    vim.api.nvim_set_current_win(view.explorer_win)
  end
end

function M.show_help(view)
  view = view or M.get_current()
  if not view or not valid(view) or M.get_current() ~= view then
    return
  end
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local scope = win == view.explorer_win and "explorer" or "diff"
  if win == view.right_win and not current_buffer_view(buf) then
    return
  end
  local shared = lease.buffers[buf]
  local bindings = {}
  local scopes = scope == "explorer" and { scope } or { "diff", "diff_visual", "diff_operator" }
  for _, current_scope in ipairs(scopes) do
    local mode = keymaps.scopes[current_scope]
    local installed = vim.api.nvim_buf_get_keymap(buf, mode)
    local owned = view.keymap_callbacks[buf] or {}
    if mode ~= "n" then
      owned = owned[mode] or {}
    end
    local maps = shared and (mode == "n" and shared.maps or shared.mode_maps[mode]) or {}
    local conditions = keymaps.conditions(active_keymaps[current_scope])
    for _, binding in ipairs(active_keymaps[current_scope]) do
      local callback = owned[binding.lhs]
      if not callback and shared and shared.owners[view.id] and maps[binding.lhs] then
        callback = maps[binding.lhs].dispatch
      end
      for _, mapping in ipairs(installed) do
        if
          callback
          and (not conditions[binding.lhs] or conditions[binding.lhs](view))
          and mapping.callback == callback
          and (mapping.lhsraw == binding.raw or mapping.lhsrawalt == binding.raw)
        then
          bindings[#bindings + 1] = binding
          break
        end
      end
    end
  end
  help.open(view, scope, bindings)
end

function M.show_path(view, path)
  view = view or M.get_current()
  if not view or not valid(view) then
    return
  end
  path = path or view.selected_path
  if not path or not view.tree or not view.tree.nodes[path] then
    return
  end
  popup.open(view, "path_popup", " " .. ui.label(view.ui_icons, "path", "Full path") .. " ", {
    explorer.display(view.root:gsub("/$", "") .. "/" .. path),
    "",
    "Close path: q / Esc / K",
  }, { "q", "<Esc>", "K" })
end

function M.next_file(view, amount)
  view = view or M.get_current()
  if not view or not valid(view) or #view.entries == 0 then
    return
  end
  view.pending_hunk = nil
  local index = 1
  for i, entry in ipairs(view.entries) do
    if entry.path == view.selected_path then
      index = i
      break
    end
  end
  index = math.max(1, math.min(#view.entries, index + (amount or 1)))
  if
    view.entries[index].path == view.selected_path
    and phase.has_content(view)
    and not view.error
    and not view.navigation
  then
    local path = view.entries[index].path
    local cursor = windows.explorer_visible(view)
      and view.rows
      and view.rows[vim.api.nvim_win_get_cursor(view.explorer_win)[1] - 3]
    if explorer.reveal(view.collapsed, path) or not cursor or cursor.path ~= path then
      render(view, path)
    end
    return
  end
  M.select(view, view.entries[index].path)
end

local function hunk_window(view)
  return vim.api.nvim_get_current_win() == view.left_win and view.left_win or view.right_win
end

local function boundary_hunk(view, last)
  view = view or M.get_current()
  if not view or not valid(view) then
    return
  end
  view.pending_hunk = nil
  local win = hunk_window(view)
  local row = hunks.boundary(view, win, last)
  if row then
    hunks.place(view, win, row)
  end
end

function M.first_hunk(view)
  boundary_hunk(view, false)
end
function M.last_hunk(view)
  boundary_hunk(view, true)
end

function M.select_hunk(view, count)
  view = view or M.get_current()
  if view and valid(view) then
    hunks.select(view, vim.api.nvim_get_current_win(), count)
  end
end

function M.next_change(view, amount)
  view = view or M.get_current()
  if not view or not valid(view) then
    return
  end
  local win = hunk_window(view)
  amount = amount or 1
  for _ = 1, math.abs(amount) do
    if not hunks.move(view, win, amount > 0 and 1 or -1) then
      break
    end
  end
end

continue_hunk = function(view)
  local pending = view.pending_hunk
  if not pending then
    return
  end
  if
    not lifetime.current(view, pending.ticket)
    or view.navigation
    or view.selected_path ~= pending.path
    or vim.api.nvim_get_current_tabpage() ~= view.tab
  then
    view.pending_hunk = nil
    return
  end
  if not phase.settled(view) then
    return
  end
  local function land(row)
    hunks.place(view, pending.win, row)
    pending.last = { path = view.selected_path, row = row }
    pending.remaining = pending.remaining - 1
  end
  if pending.landing == "restore" then
    vim.api.nvim_win_set_cursor(pending.win, {
      math.min(
        pending.last.row,
        vim.api.nvim_buf_line_count(view[pending.win == view.left_win and "left_buf" or "right_buf"])
      ),
      0,
    })
    view.pending_hunk = nil
    return
  elseif pending.landing then
    local row = hunks.boundary(view, pending.win, pending.direction < 0)
    if row then
      land(row)
    end
    pending.landing = false
  end
  while pending.remaining > 0 do
    if hunks.move(view, pending.win, pending.direction) then
      land(vim.api.nvim_win_get_cursor(pending.win)[1])
    else
      local index
      for i, entry in ipairs(view.entries) do
        if entry.path == view.selected_path then
          index = i
          break
        end
      end
      local next_entry = index and view.entries[index + pending.direction]
      local path
      if next_entry then
        path, pending.landing = next_entry.path, true
      elseif pending.last.path ~= view.selected_path and view.by_path[pending.last.path] then
        path, pending.landing = pending.last.path, "restore"
      else
        break
      end
      select(view, path, true)
      pending.ticket, pending.path = lifetime.ticket(view, "selection"), path
      return
    end
  end
  view.pending_hunk = nil
end

function M.next_hunk(view, amount)
  view = view or M.get_current()
  if not view or not valid(view) or not phase.settled(view) or view.navigation or not view.selected_path then
    return
  end
  amount = amount or 1
  if amount == 0 then
    return
  end
  local win = hunk_window(view)
  view.pending_hunk = {
    ticket = lifetime.ticket(view, "selection"),
    path = view.selected_path,
    win = win,
    remaining = math.abs(amount),
    direction = amount > 0 and 1 or -1,
    last = { path = view.selected_path, row = vim.api.nvim_win_get_cursor(win)[1] },
  }
  continue_hunk(view)
end

function M.scroll(view, direction)
  if not valid(view) then
    return
  end
  local lines = math.max(1, math.floor(vim.api.nvim_win_get_height(view.right_win) / 4))
  vim.api.nvim_win_call(view.right_win, function()
    vim.cmd("normal! " .. lines .. vim.keycode(direction > 0 and "<C-e>" or "<C-y>"))
  end)
end

function M.edit_file(view, path)
  local full = view.manager.root .. "/" .. path
  local stat = vim.uv.fs_lstat(full)
  if not stat or stat.type ~= "file" then
    vim.notify("diffreel: no regular worktree file to edit", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_cmd({ cmd = "tabedit", args = { full }, magic = { file = false, bar = false } }, {})
end

function M.refresh(view)
  view = view or current_tab_view()
  if not view or not valid(view) then
    return
  end
  phase.enter(view, "retrying")
  render(view)
  if view.pr_target then
    pr.cancel(view)
    local recovery = {}
    view.pr_recovery = recovery
    local previous = view.manager
    manager.get(M, view, notify, function(err, manager)
      if not valid(view) or view.pr_recovery ~= recovery then
        return
      end
      if err then
        view.pr_recovery = nil
        phase.enter(view, "stopped", tostring(err))
        render(view)
        return
      end
      view.manager = manager
      local ticket = lifetime.ticket(view, "manager")
      if previous ~= manager and view.pr then
        manager.backend:request(
          "pr/restore",
          { view_id = view.id, snapshot = view.pr, comparison = view.resolved_spec },
          function(restore_error, snapshot)
            if not lifetime.current(view, ticket) or view.pr_recovery ~= recovery then
              return
            end
            if restore_error then
              view.pr_recovery = nil
              phase.enter(view, "stopped", tostring(restore_error))
              render(view)
            else
              view.comparison = snapshot
              pr.start(view, render, activate_pr)
            end
          end
        )
      else
        pr.start(view, render, activate_pr)
      end
    end)
    return
  end
  if not view.manager or view.manager.backend.closed then
    manager.get(M, view, notify, function(err, manager)
      if not valid(view) then
        return
      end
      if err then
        phase.enter(view, "stopped", tostring(err))
        render(view)
      else
        view.manager = manager
        open_comparison(view)
      end
    end)
  elseif not view.comparison then
    open_comparison(view)
  else
    local ticket = lifetime.ticket(view, "comparison")
    view.manager.backend:request(
      "comparison/refresh",
      { comparison_id = view.comparison.comparison_id },
      function(err, snapshot)
        if not lifetime.current(view, ticket) then
          return
        end
        if err then
          phase.enter(view, "stopped", tostring(err))
          render(view)
        elseif view.comparison.comparison_id == snapshot.comparison_id then
          receive(view, snapshot)
        end
      end
    )
  end
end

local function dispose(view)
  if not view.alive then
    return
  end
  phase.enter(view, "closing")
  inline.dispose(view)
  pr.cancel(view)
  leave(view)
  phase.enter(view, "disposed")
  view.pending_hunk, view.deferred_path = nil, nil
  M.views[view.id] = nil
  local pending = view.pending_manager
  view.pending_manager = nil
  if pending and not pending.ready then
    local needed = false
    for _, waiting in ipairs(pending.waiters) do
      if valid(waiting.view) and waiting.view.pending_manager == pending then
        needed = true
      end
    end
    if not needed then
      manager.cancel(M, pending)
    end
  end
  local failures = {}
  local function cleanup(action)
    local ok, err = pcall(action)
    if not ok then
      failures[#failures + 1] = tostring(err)
    end
  end
  cleanup(function()
    full_name.dispose(view)
  end)
  cleanup(function()
    help.close(view)
  end)
  cleanup(function()
    popup.close(view, "path_popup")
  end)
  for _, win in ipairs(windows.engine_windows(view)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if buf == view.left_buf or buf == view.empty_buf or buf == view.right_buf then
        cleanup(function()
          vim.api.nvim_win_call(win, function()
            presentation.diffoff(view, win)
          end)
        end)
      end
    end
  end
  cleanup(function()
    presentation.dispose(view)
  end)
  for _, win in ipairs(panel.windows(view)) do
    cleanup(function()
      presentation.restore(view, win)
    end)
  end
  cleanup(function()
    layout.dispose(view)
  end)
  if view.manager and not view.manager.backend.closed then
    cleanup(function()
      view.manager.backend:request("comparison/close", { view_id = view.id }, function() end)
    end)
  end
  -- A failing buffer-enter hook can leave an incoming lease before view.right_buf is assigned.
  for _, buf in ipairs(vim.tbl_keys(lease.buffers)) do
    local borrowed = lease.buffers[buf]
    if borrowed and borrowed.owners[view.id] then
      cleanup(function()
        lease.release(buf, view.id)
      end)
    end
  end
  for _, buf in ipairs({ view.explorer_buf, view.left_buf, view.empty_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      cleanup(function()
        vim.api.nvim_buf_delete(buf, { force = true })
      end)
    end
  end
  if #failures > 0 then
    vim.schedule(function()
      vim.notify(
        "diffreel: view closed with a restoration warning: " .. failures[1]:match("[^\n]+"),
        vim.log.levels.WARN
      )
    end)
  end
  if view.opened then
    emit(view, "Close")
  end
end

function M.close(view)
  view = view or current_tab_view()
  if not view or not view.alive or view.closing then
    return
  end
  phase.enter(view, "closing")
  local temporary = vim.tbl_contains(vim.api.nvim_list_wins(), function(win)
    return vim.fn.win_gettype(win) == "autocmd"
  end, { predicate = true })
  if buffers.busy() or view.layout_changing or temporary then
    -- Changing focus does not unwind a temporary loading window or an active buffer assignment.
    vim.defer_fn(function()
      phase.enter(view, "reopened")
      M.close(view)
    end, 1)
    return
  end
  inline.clear(view)
  return lease.preserve_buffer(view.right_buf, function()
    local current = vim.api.nvim_get_current_tabpage()
    local closed, close_error = pcall(function()
      if vim.api.nvim_tabpage_is_valid(view.tab) then
        if current ~= view.tab then
          vim.api.nvim_set_current_tabpage(view.tab)
        end
        if #vim.api.nvim_list_tabpages() == 1 then
          for _, win in ipairs(panel.windows(view)) do
            if vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_win_call(win, function()
                presentation.diffoff(view, win)
              end)
              presentation.restore(view, win)
            end
          end
          -- Reusing a review window revives cached options and diff membership of its hidden buffers.
          vim.cmd("tabnew")
          presentation.restore_window(vim.api.nvim_get_current_win(), view.return_options)
          vim.api.nvim_set_current_tabpage(view.tab)
        end
        vim.cmd("tabclose")
      end
    end)
    local after_close = vim.api.nvim_get_current_tabpage()
    dispose(view)
    local target = current ~= view.tab and current or view.return_tab
    if vim.api.nvim_get_current_tabpage() == after_close and vim.api.nvim_tabpage_is_valid(target) then
      vim.api.nvim_set_current_tabpage(target)
    end
    if not closed then
      vim.schedule(function()
        vim.notify(
          "diffreel: close completed after a window callback error: " .. tostring(close_error),
          vim.log.levels.WARN
        )
      end)
    end
  end)
end

function M.shutdown()
  if shutting_down then
    return
  end
  shutting_down = true
  spinner.stop()
  for _, view in pairs(vim.tbl_extend("force", {}, M.views)) do
    dispose(view)
  end
  for _, active in pairs(M.managers) do
    manager.cancel(M, active)
  end
  M.managers = {}
  pr.shutdown()
  install.shutdown()
  completion.shutdown()
  shutting_down = false
end

function M.setup(opts)
  opts = opts == nil and {} or opts
  assert(type(opts) == "table", "diffreel: setup options must be a table")
  local config = vim.tbl_extend("force", M.config, opts)
  config.explorer = options.explorer(opts.explorer, M.config.explorer)
  config.ui_icons = ui.resolve(opts.ui_icons, M.config.ui_icons)
  config.spinner = options.spinner(opts.spinner, M.config.spinner)
  options.validate(config)
  assert(config.backend == "rust", "diffreel uses Rust; remove the legacy backend option")
  for _, name in ipairs({ "width", "max_bytes", "reconcile_ms" }) do
    local value = config[name]
    local maximum = name == "width" and 2147483647 or 9007199254740991
    assert(
      value == nil or (type(value) == "number" and value > 0 and value <= maximum and value % 1 == 0),
      "diffreel: " .. name .. " must be a positive integer within its supported range"
    )
  end
  for _, name in ipairs({ "watch", "auto_install" }) do
    assert(config[name] == nil or type(config[name]) == "boolean", "diffreel: " .. name .. " must be a boolean")
  end
  assert(
    config.daemon == nil or (type(config.daemon) == "string" and config.daemon ~= ""),
    "diffreel: daemon must be a nonempty executable path"
  )
  local resolved = active_keymaps
  if opts.keymaps ~= nil or not resolved then
    resolved = keymaps.resolve(config.keymaps)
  end
  assert(
    (not next(M.views) and not next(lease.buffers)) or vim.deep_equal(resolved, active_keymaps),
    "diffreel: close all reviews before changing keymaps"
  )
  if config.keymaps ~= nil then
    config.keymaps = vim.deepcopy(config.keymaps)
  end
  for _, name in ipairs({ "paths", "exclude" }) do
    if config[name] ~= nil then
      config[name] = vim.deepcopy(config[name])
    end
  end
  local colors = highlights.prepare(config.on_highlight)
  highlights.apply(colors)
  M.config, active_keymaps = config, resolved
  spinner.configure(config.spinner)
  user_command("Diffreel", function(args)
    local values = args.fargs
    if #values == 0 then
      local view = current_tab_view()
      if view then
        M.close(view)
        return
      end
    end
    local parsed = options.parse(values)
    if parsed.help then
      vim.cmd("help diffreel-commands")
      return
    end
    M.open(parsed)
  end, { nargs = "*", desc = "Review Git changes with diffreel", complete = command_complete })
  user_command("DiffreelClose", function()
    M.close()
  end, {})
  user_command("DiffreelRefresh", function()
    M.refresh()
  end, {})
  user_command("DiffreelLayout", function(args)
    if args.args == "" then
      M.cycle_layout()
    else
      M.set_layout(nil, args.args)
    end
  end, {
    nargs = "?",
    complete = function(lead)
      return vim.tbl_filter(function(mode)
        return mode:sub(1, #lead) == lead
      end, { "side_by_side", "stacked", "inline" })
    end,
    desc = "Change the current review layout",
  })
  user_command("DiffreelPRCacheClear", function(args)
    local opts = options.parse(args.fargs)
    for name in pairs(opts) do
      assert(name == "root", "diffreel: PRCacheClear accepts only --repo/-C")
    end
    local root = opts.root
      or (current_tab_view() and current_tab_view().root)
      or vim.fs.root(vim.api.nvim_buf_get_name(0), { ".git" })
      or vim.fs.root(vim.fn.getcwd(), { ".git" })
    assert(root, "diffreel: current file is not in a Git repository")
    root = assert(vim.uv.fs_realpath(vim.fs.root(root, { ".git" }) or root))
    local manager = M.managers[root]
    local function cleared(err, value)
      vim.notify(
        err or ("diffreel: removed " .. value.removed_refs .. " PR cache refs"),
        err and vim.log.levels.ERROR or vim.log.levels.INFO
      )
    end
    if manager and manager.ready and not manager.backend.closed then
      manager.backend:request("pr/cache-clear", {}, cleared)
    else
      pr.clear(M.config, root, cleared)
    end
  end, { nargs = "*", complete = command_complete, desc = "Clear unused PR snapshot refs in this repository" })
  user_command("DiffreelInstall", function()
    vim.notify("diffreel: preparing daemon…")
    install.ensure({ managed = true }, function(err, result)
      vim.notify(
        err or ("diffreel: daemon installed at " .. result.path),
        err and vim.log.levels.ERROR or vim.log.levels.INFO
      )
    end)
  end, { desc = "Install the daemon for this plugin version" })
  local group = vim.api.nvim_create_augroup("diffreel", { clear = true })
  local function recolor()
    for _, view in pairs(M.views) do
      if view.alive then
        view.explorer_render = nil
        render(view)
      end
    end
  end
  recolor()
  vim.api.nvim_create_autocmd({ "CursorMoved", "WinEnter", "BufWinEnter", "WinScrolled", "WinResized" }, {
    group = group,
    callback = function(event)
      if full_name.owns(tonumber(event.match)) then
        return
      end
      for _, view in pairs(M.views) do
        full_name.update(view)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave", "TabLeave" }, {
    group = group,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      for _, view in pairs(M.views) do
        if view.explorer_win == win then
          full_name.close(view)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = {
      "wrap",
      "cursorline",
      "number",
      "relativenumber",
      "numberwidth",
      "foldcolumn",
      "signcolumn",
      "statuscolumn",
      "winbar",
    },
    callback = function()
      if full_name.owns(vim.api.nvim_get_current_win()) then
        return
      end
      for _, view in pairs(M.views) do
        full_name.update(view)
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorSchemePre", { group = group, callback = highlights.before_colorscheme })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      local ok, colors = pcall(highlights.prepare, M.config.on_highlight, true)
      if not ok then
        vim.notify(tostring(colors), vim.log.levels.ERROR)
        colors = highlights.prepare(false, true)
      end
      highlights.apply(colors)
      recolor()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      local win = tonumber(event.match)
      for _, view in pairs(M.views) do
        if not view.layout_changing and vim.tbl_contains(windows.owned_windows(view), win) then
          inline.clear(view)
          view.layout_pending = nil
          for _, pane in ipairs(windows.owned_windows(view)) do
            if vim.api.nvim_win_is_valid(pane) then
              local copied = view.presentation and vim.deepcopy(view.presentation[pane])
              pcall(presentation.diffoff, view, pane)
              pcall(presentation.restore, view, pane)
              -- CTRL-W T can copy review options before WinClosed; disposal still needs their original ownership.
              if copied then
                view.presentation[pane] = copied
              end
            end
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = {
      "diffopt",
      "diffexpr",
      "diffanchors",
      "tabstop",
      "vartabstop",
      "number",
      "relativenumber",
      "numberwidth",
      "foldcolumn",
      "signcolumn",
      "statuscolumn",
    },
    callback = function()
      vim.schedule(function()
        for _, view in pairs(M.views) do
          if view.layout == "inline" then
            rebuild_inline(view)
          end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "TabEnter", "TabLeave" }, {
    group = group,
    callback = function(event)
      local tab = vim.api.nvim_get_current_tabpage()
      for _, view in pairs(vim.tbl_extend("force", {}, M.views)) do
        if view.tab == tab then
          if event.event == "TabLeave" then
            if valid(view) then
              layout.capture_ratio(view)
            end
            leave(view)
          else
            enter(view)
          end
        end
      end
    end,
  })
  local resize_scheduled = false
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      panel.resized()
      for _, view in pairs(M.views) do
        view.layout_resize_pending = true
      end
      if resize_scheduled then
        return
      end
      resize_scheduled = true
      vim.schedule(function()
        resize_scheduled = false
        for _, view in pairs(vim.tbl_extend("force", {}, M.views)) do
          resize_view(view)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      for _, view in pairs(M.views) do
        if valid(view) then
          layout.capture_ratio(view)
          render(view)
          if view.layout == "inline" and not view.inline_pending then
            rebuild_inline(view)
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      vim.schedule(function()
        for _, view in pairs(M.views) do
          if
            valid(view)
            and view.layout == "inline"
            and not view.inline_pending
            and view.ready
            and not inline.current(view)
          then
            rebuild_inline(view)
          end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufModifiedSet", "BufWritePost" }, {
    group = group,
    callback = function(event)
      buffer_changed(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "fileformat", "bomb", "endofline", "modified" },
    callback = function()
      -- OptionSet leaves <abuf> at zero, even when a buffer-local option changes.
      buffer_changed(vim.api.nvim_get_current_buf())
    end,
  })
  vim.api.nvim_create_autocmd({ "TabEnter", "TabClosed", "WinClosed", "BufWinEnter" }, {
    group = group,
    callback = function(event)
      if event.event == "WinClosed" and full_name.owns(tonumber(event.match)) then
        return
      end
      vim.schedule(function()
        if event.event == "TabEnter" then
          presentation.clean_copies()
        end
        for _, view in pairs(vim.tbl_extend("force", {}, M.views)) do
          if event.event == "TabEnter" then
            resize_view(view)
          end
          if not valid(view) then
            dispose(view)
          elseif
            (event.event == "TabEnter" or event.event == "TabClosed")
            and view.comparison
            and view.manager
            and not view.manager.backend.closed
          then
            view.manager.backend:request("view/update", {
              view_id = view.id,
              comparison_id = view.comparison.comparison_id,
              visible = vim.api.nvim_get_current_tabpage() == view.tab,
              path = view.selected_path,
            }, function() end)
          end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      for _, view in pairs(M.views) do
        local mutable = view.spec.right == "worktree" or view.spec.right == ":0" or view.spec.left == ":0"
        for _, path in ipairs(view.spec.paths or {}) do
          mutable = mutable or (path:sub(1, 2) == ":(" and path:find("attr:", 1, true) ~= nil)
        end
        if valid(view) and not view.pr_target and view.tab == vim.api.nvim_get_current_tabpage() and mutable then
          local manager = view.manager
          -- Monitoring already reconciles changes; a focus refresh would make the next selection wait for Git.
          if manager and manager.watch and manager.backend and not manager.backend.closed and view.comparison then
            if not view.switching then
              manager.backend:request("view/update", {
                view_id = view.id,
                comparison_id = view.comparison.comparison_id,
                visible = true,
                path = view.selected_path,
              }, function() end)
            end
          else
            M.refresh(view)
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      vim.schedule(function()
        for _, view in pairs(M.views) do
          if valid(view) and view.comparison and not view.switching then
            if vim.api.nvim_win_get_buf(view.right_win) ~= view.right_buf then
              if not view.navigation then
                phase.enter(view, "paused")
                inline.clear(view)
                view.pending_hunk = nil
                for _, win in ipairs(windows.engine_windows(view)) do
                  pcall(vim.api.nvim_win_call, win, function()
                    presentation.diffoff(view, win)
                  end)
                end
                presentation.restore(view, view.left_win)
                presentation.restore(view, view.right_win)
                render(view)
              end
            elseif view.navigation then
              phase.enter(view, "resumed")
              receive(view, view.comparison)
            end
          end
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.shutdown })
end

return M
