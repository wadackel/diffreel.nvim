vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function write(data)
  local file = assert(io.open(root .. "/main.lua", "wb"))
  file:write(data)
  file:close()
end
local function git(args)
  local cmd = {
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
  vim.list_extend(cmd, args)
  local result = vim.system(cmd, { cwd = root }):wait()
  assert(result.code == 0, result.stderr)
end
local plugin
local ok, err = xpcall(function()
  git({ "init", "-q" })
  write("local value = 1\n")
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  write("local value = 2\n")
  vim.cmd("filetype on")
  vim.api.nvim_cmd({ cmd = "edit", args = { root .. "/main.lua" } }, {})
  local normal = vim.api.nvim_get_current_win()
  local buffer = vim.api.nvim_get_current_buf()
  local hidden = vim.bo[buffer].bufhidden
  local called = 0
  local original = function()
    called = called + 1
  end
  vim.keymap.set("n", "q", original, { buffer = buffer })
  plugin = require("diffreel")
  plugin.setup({ backend = "rust", watch = false })
  local view = plugin.open({ root = root })
  assert(
    vim.wait(10000, function()
      return view.ready or view.error
    end, 5),
    "View did not become ready"
  )
  assert(not view.error, view.error)
  assert(view.right_buf == buffer, "Normal file buffer was duplicated")
  assert(vim.bo[buffer].filetype == "lua", "Normal FileType processing was lost")
  assert(vim.api.nvim_buf_get_lines(view.left_buf, 0, -1, false)[1] == "local value = 1")
  assert(vim.wo[view.left_win].diff and vim.wo[view.right_win].diff)
  vim.api.nvim_set_current_win(normal)
  vim.api.nvim_feedkeys("q", "xt", false)
  assert(called == 1, "Review mapping changed the normal window")
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local value = 99" })
  write("local value = 3\n")
  plugin.refresh(view)
  assert(
    vim.wait(10000, function()
      return view.disk_conflict
    end, 5),
    "External conflict was not shown"
  )
  assert(vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1] == "local value = 99")
  assert(vim.bo[buffer].modified, "Unsaved flag was cleared")
  plugin.close(view)
  assert(vim.api.nvim_buf_is_valid(buffer) and vim.bo[buffer].modified, "Closing discarded the normal buffer")
  assert(vim.bo[buffer].bufhidden == hidden, "Buffer option was not restored")
  vim.api.nvim_set_current_win(normal)
  vim.api.nvim_feedkeys("q", "xt", false)
  assert(called == 2, "Original mapping was not restored")
end, debug.traceback)
if plugin then
  plugin.shutdown()
end
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
