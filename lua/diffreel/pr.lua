local explorer = require("diffreel.explorer")
local install = require("diffreel.install")
local lifetime = require("diffreel.lifetime")
local phase = require("diffreel.phase")
local M = {}
local clears = {}

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function cleanup(state)
  close_timer(state.timer)
  state.timer = nil
  if not state.manager.backend.closed then
    if state.candidate then
      state.manager.backend:request("comparison/close", { view_id = state.candidate }, function() end)
      state.candidate = nil
    end
    if state.previous then
      state.manager.backend:request("comparison/close", { view_id = state.previous }, function() end)
      state.previous = nil
    end
  end
  state.rollback = nil
end

function M.cancel(view)
  view.pr_recovery = nil
  local state = view.pr_request
  if not state then
    return
  end
  view.pr_request = nil
  if state.job_id and not state.manager.backend.closed then
    state.manager.backend:request("pr/cancel", { job_id = state.job_id }, function() end)
  end
  if state.rollback and lifetime.current(view, state.ticket) and not state.manager.backend.closed then
    state.manager.backend:request("view/update", state.rollback, function() end)
  end
  cleanup(state)
end

local function current(view, state)
  return view.pr_request == state and lifetime.current(view, state.ticket) and not state.manager.backend.closed
end

local function fail(view, state, err)
  if not current(view, state) then
    cleanup(state)
    return
  end
  M.cancel(view)
  phase.enter(view, "stopped", tostring(err))
  state.render(view)
end

local function candidate(view, state, metadata)
  state.candidate = view.id .. "-pr-" .. state.sequence
  local request = {
    view_id = state.candidate,
    left = metadata.merge_base,
    right = metadata.head,
    paths = view.spec.paths,
    file = view.spec.file,
    untracked = false,
  }
  state.manager.backend:request("comparison/open", request, function(err, snapshot)
    if not current(view, state) then
      cleanup(state)
      return
    end
    if err then
      fail(view, state, err)
      return
    end
    local tree = explorer.build(snapshot.entries)
    local entries = explorer.ordered(tree, view.explorer_options.mode)
    local preferred = view.selected_path or view.preferred_path
    local entry = entries[1]
    for _, item in ipairs(entries) do
      if item.path == preferred then
        entry = item
        break
      end
    end
    local prepared = entry and { path = entry.path } or nil
    local remaining = entry and 2 or 0
    local function activate()
      if remaining > 0 or not current(view, state) then
        return
      end
      local function transfer()
        state.manager.backend:request("view/update", {
          view_id = view.id,
          comparison_id = snapshot.comparison_id,
          visible = vim.api.nvim_get_current_tabpage() == view.tab,
          path = entry and entry.path,
        }, function(update_error)
          if not current(view, state) then
            cleanup(state)
            return
          end
          if update_error then
            fail(view, state, update_error)
            return
          end
          view.pr_request = nil
          cleanup(state)
          state.activate(view, snapshot, metadata, prepared)
        end)
      end
      if view.comparison then
        state.rollback = {
          view_id = view.id,
          comparison_id = view.comparison.comparison_id,
          visible = vim.api.nvim_get_current_tabpage() == view.tab,
          path = view.selected_path,
        }
        state.previous = state.candidate .. "-previous"
        -- The old comparison can be evicted between transferring the association and receiving its response.
        local retained = vim.tbl_extend("force", state.rollback, { view_id = state.previous, visible = false })
        state.manager.backend:request("view/update", retained, function(hold_error)
          if not current(view, state) then
            cleanup(state)
          elseif hold_error then
            fail(view, state, hold_error)
          else
            transfer()
          end
        end)
      else
        transfer()
      end
    end
    if not entry then
      activate()
      return
    end
    for _, side in ipairs({ "left", "right" }) do
      local data = entry[side]
      local function received(read_error, value)
        if not current(view, state) then
          return
        end
        if read_error then
          fail(view, state, read_error)
          return
        end
        prepared[side], remaining = value, remaining - 1
        activate()
      end
      if data.kind == "limited" then
        received(nil, data)
      elseif data.kind == "missing" then
        received(
          nil,
          { exists = false, kind = "missing", lines = { "" }, endofline = false, mode = "000000", size = 0 }
        )
      else
        state.manager.backend:request("blob/read", { oid = data.oid, mode = data.mode }, received)
      end
    end
  end)
end

function M.start(view, render, activate)
  M.cancel(view)
  view.pr_sequence = (view.pr_sequence or 0) + 1
  local state = {
    sequence = view.pr_sequence,
    manager = view.manager,
    session = view.manager.session_id,
    ticket = lifetime.ticket(view, "manager"),
    render = render,
    activate = activate,
  }
  view.pr_request = state
  view.pending_hunk = nil
  phase.enter(view, "retrying")
  state.timer = vim.uv.new_timer()
  state.timer:start(
    125000,
    0,
    vim.schedule_wrap(function()
      fail(view, state, "PR acquisition timed out; refresh to retry")
    end)
  )
  render(view)
  view.manager.backend:request(
    "pr/prepare",
    { view_id = view.id, pr = view.pr_target, request_id = state.sequence },
    function(err, result)
      if not current(view, state) then
        if result and not state.manager.backend.closed then
          state.manager.backend:request("pr/cancel", { job_id = result.job_id }, function() end)
        end
        return
      end
      if err then
        fail(view, state, err)
        return
      end
      state.job_id = result.job_id
    end
  )
end

function M.notify(view, method, params)
  local state = view.pr_request
  if
    not state
    or params.request_id ~= state.sequence
    or params.view_id ~= view.id
    or params.session_id ~= state.session
  then
    return
  end
  if not current(view, state) then
    return
  end
  if method == "pr/error" then
    fail(view, state, params.error)
  elseif method == "pr/prepared" then
    state.job_id = params.job_id
    candidate(view, state, params.result)
  end
end

function M.clear(config, root, done)
  local state = {}
  clears[state] = true
  local function finish(err, value)
    if not clears[state] then
      return
    end
    clears[state] = nil
    done(err, value)
  end
  state.cancel = install.ensure(config, function(err, prepared)
    if not clears[state] then
      return
    end
    if err then
      finish(err)
      return
    end
    local ok, process = pcall(
      vim.system,
      { prepared.path, "--pr-cache-clear", "--root", root },
      { text = true, timeout = 15000 },
      vim.schedule_wrap(function(result)
        if not clears[state] then
          return
        end
        if result.code ~= 0 then
          finish(vim.trim(result.stderr or "PR cache clear failed"))
        else
          local parsed, value = pcall(vim.json.decode, result.stdout)
          if parsed then
            finish(nil, value)
          else
            finish("Invalid PR cache response")
          end
        end
      end)
    )
    if ok then
      state.process = process
    else
      finish("Cannot start PR cache cleanup")
    end
  end)
end

function M.shutdown()
  local pending = clears
  clears = {}
  for state in pairs(pending) do
    if state.cancel then
      state.cancel()
    end
    if state.process then
      pcall(state.process.kill, state.process, 15)
    end
  end
end

return M
