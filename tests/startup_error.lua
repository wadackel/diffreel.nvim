vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local roots = {}
local ok, err = xpcall(function()
  plugin.setup({ backend = "rust", daemon = vim.env.DIFFREEL_DAEMON, watch = false })
  local plain = vim.fn.tempname()
  vim.fn.mkdir(plain, "p")
  local broken = vim.fn.tempname()
  vim.fn.mkdir(broken .. "/.git", "p")
  roots = { plain, broken }
  for _, root in ipairs(roots) do
    local view = plugin.open({ root = root })
    assert(
      vim.wait(10000, function()
        return view.error ~= nil
      end, 5),
      "Startup failure did not reach the view"
    )
    assert(view.error:find("Could not find a git repository", 1, true), view.error)
    plugin.close(view)
  end
end, debug.traceback)
plugin.shutdown()
for _, root in ipairs(roots) do
  vim.fn.delete(root, "rf")
end
if not ok then
  error(err, 0)
end
print(vim.json.encode({ passed = true }))
