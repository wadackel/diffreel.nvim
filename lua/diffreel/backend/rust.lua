local Backend = {}
Backend.__index = Backend

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

function Backend.new(opts, notify)
  local self = setmetatable({ pending = {}, notify = notify or function() end }, Backend)
  local binary = assert(opts.daemon or vim.g.diffreel_daemon, "Prepare a daemon before starting the backend")
  local command = { binary, "--root", opts.root }
  if opts.watch == false then
    command[#command + 1] = "--no-watch"
  end
  if opts.reconcile_ms then
    vim.list_extend(command, { "--reconcile-ms", ("%.0f"):format(opts.reconcile_ms) })
  end
  if opts.max_bytes then
    vim.list_extend(command, { "--max-bytes", ("%.0f"):format(opts.max_bytes) })
  end
  self.rpc = vim.lsp.rpc.start(command, {
    notification = function(method, params)
      if not self.closed then
        self.notify(method, params)
      end
    end,
    on_error = function(_, err)
      self.last_error = vim.inspect(err)
    end,
    on_exit = vim.schedule_wrap(function(code, signal)
      local expected = self.closed or self.shutting_down
      self.dead = true
      self:close()
      if not expected then
        self.notify("backend/error", { message = self.last_error or ("Daemon exited: " .. code .. "/" .. signal) })
      end
    end),
  }, { cwd = opts.root })
  return self
end

function Backend:request(method, params, done)
  if self.closed then
    done(self.last_error or "Backend is closed")
    return
  end
  if method == "shutdown" then
    self.shutting_down = true
  end
  local completed, id = false, nil
  local timer = vim.uv.new_timer()
  local function finish(err, result)
    if completed then
      return
    end
    completed = true
    close_timer(timer)
    if id then
      self.pending[id] = nil
    end
    done(err, result)
  end
  local sent
  sent, id = self.rpc.request(method, params or {}, function(err, result)
    finish(err and err.message or nil, result)
  end)
  if not sent then
    finish("Cannot send daemon request")
    return
  end
  self.pending[id] = finish
  timer:start(
    120000,
    0,
    vim.schedule_wrap(function()
      finish("Daemon request timed out: " .. method)
      self:close()
    end)
  )
end

function Backend:close()
  if self.closed then
    return
  end
  self.closed = true
  local pending = self.pending
  self.pending = {}
  for _, finish in pairs(pending) do
    finish(self.last_error or "Backend is closed")
  end
  if self.rpc and not self.rpc.is_closing() then
    self.rpc.terminate()
  end
end

return Backend
