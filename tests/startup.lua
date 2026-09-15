vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/.git", "p")
local preparing, backends = {}, {}
package.loaded["diffreel.install"] = {
  ensure = function(_, done)
    preparing[#preparing + 1] = done
    return function() end
  end,
  shutdown = function() end,
}
package.loaded["diffreel.backend.rust"] = {
  new = function()
    local backend = {}
    function backend:request(method, _, done)
      assert(method == "initialize", method)
      self.initialize = done
    end
    function backend:close()
      self.closed = true
    end
    backends[#backends + 1] = backend
    return backend
  end,
}
local plugin = require("diffreel")
plugin.setup({ daemon = "/test/daemon" })
local config = plugin.config
assert(not pcall(plugin.setup, { backend = "lua" }))
assert(plugin.config == config)
local a = plugin.open({ root = root })
assert(#preparing == 1 and #backends == 0)
preparing[1](nil, { path = "/test/daemon" })
assert(#backends == 1)
plugin.close(a)
assert(backends[1].closed, "closing the last provisional view must close its startup")
local b = plugin.open({ root = root })
preparing[2](nil, { path = "/test/daemon" })
local manager = plugin.managers[root]
backends[1].initialize("late failure")
assert(plugin.managers[root] == manager, "old initialization must not remove the new manager")
plugin.shutdown()
local c = plugin.open({ root = root })
local replacement = plugin.managers[root]
backends[2].initialize(nil, { root = root, session_id = "obsolete", protocol = 4 })
assert(plugin.managers[root] == replacement and not c.manager)
plugin.close(c)
preparing[3](nil, { path = "/test/daemon" })
assert(#backends == 2, "a cancelled download completion must not start a daemon")
local d = plugin.open({ root = root })
local e = plugin.open({ root = root })
assert(#preparing == 4, "pending managers must coalesce by root")
plugin.close(d)
preparing[4](nil, { path = "/test/daemon" })
assert(#backends == 3 and not backends[3].closed, "remaining view owns pending startup")
plugin.close(e)
assert(backends[3].closed)
plugin.shutdown()
vim.fn.delete(root, "rf")
print("startup: passed")
