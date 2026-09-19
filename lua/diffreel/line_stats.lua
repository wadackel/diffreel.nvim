local lifetime = require("diffreel.lifetime")
local M = {}
local empty = {}

function M.current(view)
  local state, comparison, manager = view.statistics, view.comparison, view.manager
  if
    state
    and comparison
    and manager
    and state.manager == manager
    and state.session_id == manager.session_id
    and state.comparison_id == comparison.comparison_id
    and state.generation == comparison.generation
    and state.compare_seq == view.compare_seq
  then
    return state
  end
end

function M.files(view)
  if not view.line_stats then
    return nil
  end
  local state = M.current(view)
  return state and state.files or empty
end

function M.start(view, render)
  if
    not view.line_stats
    or not lifetime.valid(view)
    or not view.ready
    or view.updating
    or view.error
    or not view.comparison
    or not view.manager
    or view.manager.backend.closed
    or M.current(view)
  then
    return
  end
  local manager = view.manager
  local state = {
    manager = manager,
    session_id = manager.session_id,
    compare_seq = view.compare_seq,
    comparison_id = view.comparison.comparison_id,
    generation = view.comparison.generation,
    files = {},
    additions = 0,
    deletions = 0,
    unavailable = 0,
    offset = 0,
    pending = true,
  }
  view.statistics = state
  local function current()
    return lifetime.valid(view) and view.statistics == state and M.current(view) == state and not manager.backend.closed
  end
  local function redraw()
    if state.redraw_pending then
      return
    end
    state.redraw_pending = true
    vim.defer_fn(function()
      state.redraw_pending = false
      if current() then
        render(view)
      end
    end, 16)
  end
  local request
  request = function()
    if not current() or not state.pending then
      return
    end
    local offset = state.offset
    manager.backend:request("comparison/stats", {
      comparison_id = state.comparison_id,
      generation = state.generation,
      offset = offset,
    }, function(err, result)
      if not current() or not state.pending or state.offset ~= offset then
        return
      end
      if err then
        state.error, state.pending = tostring(err), false
        redraw()
        return
      end
      if
        result.session_id ~= state.session_id
        or result.comparison_id ~= state.comparison_id
        or result.generation ~= state.generation
      then
        return
      end
      if
        type(result.files) ~= "table"
        or type(result.next_offset) ~= "number"
        or (not result.complete and result.next_offset <= offset)
      then
        state.error, state.pending = "Invalid statistics response", false
        redraw()
        return
      end
      local files = vim.tbl_extend("force", {}, state.files)
      for path, value in pairs(result.files) do
        if not files[path] then
          if value.additions and value.deletions then
            state.additions, state.deletions = state.additions + value.additions, state.deletions + value.deletions
          else
            state.unavailable = state.unavailable + 1
          end
        end
        files[path] = value
      end
      state.files, state.offset = files, result.next_offset
      state.complete, state.pending = result.complete, not result.complete
      redraw()
      if state.pending then
        vim.defer_fn(request, 5)
      end
    end)
  end
  vim.defer_fn(request, 5)
end

return M
