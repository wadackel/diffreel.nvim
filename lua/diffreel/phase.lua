local M = {}

local transitions = {
  switching = function(view)
    view.switching, view.updating = true, true
  end,
  answered = function(view)
    view.switching = false
  end,
  received = function(view)
    view.switching, view.ready, view.selection_pending = false, false, false
  end,
  selecting = function(view)
    view.ready, view.selection_pending, view.navigation = false, true, false
  end,
  ready = function(view)
    view.ready, view.error, view.selection_pending = true, nil, false
  end,
  empty = function(view)
    view.ready, view.selection_pending = true, false
  end,
  paused = function(view)
    view.navigation = true
  end,
  resumed = function(view)
    view.navigation, view.ready, view.selection_pending = false, false, false
  end,
  failed = function(view, detail)
    view.error, view.selection_pending = detail, false
  end,
  stopped = function(view, detail)
    view.error, view.updating = detail, false
  end,
  retrying = function(view)
    view.updating, view.error = true, nil
  end,
  closing = function(view)
    view.closing = true
  end,
  reopened = function(view)
    view.closing = false
  end,
  disposed = function(view)
    view.alive = false
  end,
}

function M.enter(view, name, detail)
  local transition = transitions[name]
  assert(transition, "diffreel: unknown view phase " .. tostring(name))
  transition(view, detail)
end

function M.settled(view)
  return view.ready == true and not view.updating and view.error == nil
end

function M.selected(view)
  return view.ready == true and not view.selection_pending
end

function M.has_content(view)
  return (view.ready or view.selection_pending) == true
end

function M.interactive(view)
  return view.ready == true and not view.selection_pending and not view.navigation
end

return M
