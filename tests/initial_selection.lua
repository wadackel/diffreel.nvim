vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(args)
  local command = {
    "git",
    "-c",
    "user.name=Example",
    "-c",
    "user.email=example@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=/dev/null",
  }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ "init", "-q" })
for _, path in ipairs({ "a", "b" }) do
  vim.fn.writefile({ "base" }, root .. "/" .. path)
end
git({ "add", "." })
git({ "commit", "-qm", "base" })
for _, path in ipairs({ "a", "b" }) do
  vim.fn.writefile({ "changed" }, root .. "/" .. path)
end
local diffreel = require("diffreel")
local Backend = require("diffreel.backend.rust")
local original_new, pending = Backend.new, nil
Backend.new = function(opts, notify)
  local backend = original_new(opts, notify)
  local request = backend.request
  backend.request = function(self, method, params, callback)
    return request(self, method, params, function(err, value)
      if method == "comparison/open" then
        pending = function()
          callback(err, value)
        end
      else
        callback(err, value)
      end
    end)
  end
  return backend
end
local ok, err = xpcall(function()
  diffreel.setup({ watch = false })
  local view = diffreel.open({ root = root, paths = { "a", "b" }, selected_file = "b" })
  assert(
    vim.wait(5000, function()
      return pending ~= nil
    end, 5),
    "No open response"
  )
  local target = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(view.right_win, target)
  pending()
  assert(view.navigation)
  local drained = false
  vim.schedule(function()
    drained = true
  end)
  assert(vim.wait(1000, function()
    return drained
  end, 5))
  diffreel.select(view, "a")
  assert(
    vim.wait(5000, function()
      return view.ready
    end, 5),
    view.error
  )
  local draft = view.right_buf
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "unsaved draft" })
  vim.fn.writefile({ "base" }, root .. "/a")
  for _ = 1, 2 do
    local generation = view.comparison.generation
    diffreel.refresh(view)
    assert(
      vim.wait(5000, function()
        return view.ready and not view.updating and view.comparison.generation > generation
      end, 5),
      view.error
    )
    assert(view.selected_path == "a", "Initial preference overrode an explicit choice")
    assert(view.by_path.a and view.by_path.a.buffer_only, "The retained draft left the explorer")
    assert(vim.bo[draft].modified and vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "unsaved draft")
  end
end, debug.traceback)
Backend.new = original_new
diffreel.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
