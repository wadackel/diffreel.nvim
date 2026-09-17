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
local delete_buffer = vim.api.nvim_buf_delete
local notify = vim.notify
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

  vim.fn.writefile({ "second" }, root .. "/file.txt")
  -- The first review left the source buffer dirty, and a disk conflict outranks Updating… in the status block.
  vim.api.nvim_buf_delete(source, { force = true })
  local second = plugin.open({ root = root })
  assert(vim.wait(5000, function()
    return second.ready
  end, 5))
  plugin.refresh(second)
  local overlay = second.status and second.status.win
  assert(overlay and vim.api.nvim_win_is_valid(overlay), "The status overlay was not open while updating")
  local overlay_buf = second.status.buf
  local warnings = {}
  vim.notify = function(message, level)
    warnings[#warnings + 1] = tostring(message)
    return notify(message, level)
  end
  vim.api.nvim_buf_delete = function(buf, opts)
    if buf == overlay_buf then
      error("Injected overlay buffer failure")
    end
    return delete_buffer(buf, opts)
  end
  pcall(plugin.close, second)
  vim.api.nvim_buf_delete = delete_buffer
  assert(
    vim.wait(1000, function()
      return #warnings > 0
    end, 5),
    "A failing overlay teardown was not reported"
  )
  assert(
    warnings[1]:find("Injected overlay buffer failure", 1, true),
    "The reported warning was not the injected one: " .. warnings[1]
  )
  assert(not second.alive, "A failing overlay teardown left the review alive")
  assert(second.status == nil, "A failing overlay teardown kept the overlay state")
  local after
  backend:request("debug/metrics", {}, function(failure, value)
    assert(not failure, failure)
    after = value
  end)
  assert(vim.wait(1000, function()
    return after ~= nil
  end, 5))
  assert(after.views == 0, "A failing overlay teardown retained a subscription")
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    assert(not vim.api.nvim_win_get_config(win).hide, "A failing overlay teardown left a hidden window")
  end
  if vim.api.nvim_buf_is_valid(overlay_buf) then
    delete_buffer(overlay_buf, { force = true })
  end
end, debug.traceback)
if event then
  vim.api.nvim_del_autocmd(event)
end
vim.api.nvim_win_set_buf = set_buffer
vim.api.nvim_buf_delete = delete_buffer
vim.notify = notify
if plugin then
  plugin.shutdown()
end
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
