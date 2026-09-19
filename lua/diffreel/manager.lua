local install = require("diffreel.install")
local distribution = require("diffreel.distribution")
local lifetime = require("diffreel.lifetime")
local M = {}
local valid = lifetime.valid

local function cancel_manager(registry, manager)
  if registry.managers[manager.key] == manager then
    registry.managers[manager.key] = nil
  end
  manager.cancelled = true
  if manager.cancel then
    manager.cancel()
  end
  if manager.backend then
    manager.backend:close()
  end
end

local function get_manager(registry, view, notify, callback)
  local root = view.root
  local manager = registry.managers[root]
  view.startup_seq = (view.startup_seq or 0) + 1
  local sequence = view.startup_seq
  if manager and manager.ready and not manager.backend.closed then
    callback(nil, manager)
    return
  end
  local waiter = { view = view, sequence = sequence, done = callback }
  if manager and not manager.cancelled and (not manager.backend or not manager.backend.closed) then
    view.pending_manager = manager
    manager.waiters[#manager.waiters + 1] = waiter
    return
  end
  manager = { root = root, waiters = { waiter }, ready = false, key = root, watch = registry.config.watch ~= false }
  view.pending_manager = manager
  registry.managers[root] = manager
  local config = vim.tbl_extend("force", registry.config, { root = root })
  local function owned()
    return registry.managers[root] == manager and not manager.cancelled
  end
  local function finish(err, info)
    if not owned() then
      return
    end
    if not err then
      local ok, failure = pcall(distribution.check_info, info, manager.expected)
      if not ok then
        err = tostring(failure)
      end
    end
    if err then
      cancel_manager(registry, manager)
    else
      manager.ready, manager.root, manager.session_id = true, info.root, info.session_id
    end
    local waiters = manager.waiters
    manager.waiters = {}
    for _, waiting in ipairs(waiters) do
      if valid(waiting.view) and waiting.view.startup_seq == waiting.sequence then
        waiting.view.pending_manager = nil
        waiting.done(err, manager)
      end
    end
  end
  manager.cancel = install.ensure(config, function(err, prepared)
    if not owned() then
      return
    end
    if err then
      finish(err)
      return
    end
    manager.expected = prepared.expected
    config.daemon = prepared.path
    local ok, backend = pcall(function()
      return require("diffreel.backend.rust").new(config, function(method, params)
        notify(manager, method, params)
      end)
    end)
    if not ok then
      finish(tostring(backend))
      return
    end
    manager.backend = backend
    backend:request("initialize", { protocol = distribution.protocol }, finish)
  end)
end

M.cancel, M.get = cancel_manager, get_manager

return M
