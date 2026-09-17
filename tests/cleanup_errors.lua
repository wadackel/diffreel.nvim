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
  local result = vim.system(command, { cwd = root }):wait()
  assert(result.code == 0, result.stderr)
end
local plugin, view, event
local set_buffer = vim.api.nvim_win_set_buf
local ok, err = xpcall(function()
  git({ "init", "-q" })
  vim.fn.writefile({ "baseline" }, root .. "/file.txt")
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  vim.fn.writefile({ "changed" }, root .. "/file.txt")
  plugin = require("diffreel")
  plugin.setup({ backend = "rust", watch = false })
  view = plugin.open({ root = root })
  assert(vim.wait(5000, function()
    return view.ready
  end, 5))
  local source, backend = view.right_buf, view.manager.backend
  local hidden = require("diffreel.lease").buffers[source].options.bufhidden.original
  local ignored = vim.o.eventignore
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved draft" })
  event = vim.api.nvim_create_autocmd("BufWinEnter", {
    callback = function(args)
      if args.buf == source then
        for _, win in ipairs(vim.fn.win_findbuf(source)) do
          if vim.api.nvim_win_get_config(win).hide then
            vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unexpected callback rewrite" })
            error("Injected window callback failure")
          end
        end
      end
    end,
  })
  vim.api.nvim_win_set_buf = function(win, buf)
    set_buffer(win, buf)
    if buf == source and vim.api.nvim_win_get_config(win).hide then
      error("Injected set-buffer failure")
    end
  end
  pcall(plugin.close, view)
  vim.api.nvim_win_set_buf = set_buffer
  vim.api.nvim_del_autocmd(event)
  event = nil
  local metrics
  backend:request("debug/metrics", {}, function(failure, value)
    assert(not failure, failure)
    metrics = value
  end)
  assert(vim.wait(1000, function()
    return metrics ~= nil
  end, 5))
  assert(metrics.views == 0, "Failed cleanup retained a subscription")
  assert(not require("diffreel.lease").buffers[source], "Failed cleanup retained the buffer lease")
  assert(vim.bo[source].bufhidden == hidden, "Failed cleanup did not restore bufhidden")
  assert(vim.o.eventignore == ignored, "Failed cleanup did not restore event handling")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    assert(not vim.api.nvim_win_get_config(win).hide, "Failed cleanup left a hidden window")
  end
  assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == "unsaved draft")
end, debug.traceback)
if event then
  vim.api.nvim_del_autocmd(event)
end
vim.api.nvim_win_set_buf = set_buffer
if plugin then
  plugin.shutdown()
end
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
