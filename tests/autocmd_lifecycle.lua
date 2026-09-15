vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd("filetype on")
local plugin = require("diffreel")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = assert(vim.uv.fs_realpath(root))
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
  assert(vim.system(cmd, { cwd = root }):wait().code == 0)
end
git({ "init", "-q" })
vim.fn.writefile({ "old" }, root .. "/a.txt")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile({ "new" }, root .. "/a.txt")
local ok, err = xpcall(function()
  for _, event in ipairs({ "BufWinEnter", "FileType" }) do
    for _, nested in ipairs({ false, true }) do
      plugin.setup({ watch = false })
      local view = plugin.open({ root = root })
      local called, source = false, nil
      local hook = vim.api.nvim_create_autocmd(event, {
        callback = function(args)
          if called or vim.api.nvim_buf_get_name(args.buf) ~= root .. "/a.txt" then
            return
          end
          called, source = true, args.buf
          plugin.close(view)
          if nested then
            vim.wait(20, function()
              return false
            end, 5)
          end
        end,
      })
      assert(
        vim.wait(5000, function()
          return called and not view.alive
        end, 5),
        event .. " close did not finish"
      )
      vim.api.nvim_del_autocmd(hook)
      assert(not next(plugin.views) and not next(require("diffreel.lease").buffers), event .. " left a buffer lease")
      assert(vim.api.nvim_buf_is_valid(source), "Closing the review removed its real source")
      assert(#vim.api.nvim_list_tabpages() == 1, "Closing from an autocmd left the review tab")
      plugin.shutdown()
      vim.api.nvim_buf_delete(source, { force = true })
    end
  end
  for _, mode in ipairs({ "side_by_side", "stacked", "inline" }) do
    for _, phase in ipairs({ "temporary-focus", "normal-pane", "normal-pane-error" }) do
      plugin.setup({ watch = false })
      local origin = vim.api.nvim_get_current_win()
      local view = plugin.open({ root = root, layout = mode })
      local called, source = false, nil
      local hook = vim.api.nvim_create_autocmd("BufWinEnter", {
        callback = function(args)
          if called or vim.api.nvim_buf_get_name(args.buf) ~= root .. "/a.txt" then
            return
          end
          if phase:find("normal%-pane") and vim.api.nvim_get_current_win() ~= view.right_win then
            return
          end
          called, source = true, args.buf
          plugin.close(view)
          if phase == "normal-pane-error" then
            error("User hook fixture after close")
          end
          if phase == "temporary-focus" then
            vim.schedule(function()
              vim.api.nvim_set_current_win(origin)
            end)
            vim.wait(20, function()
              return false
            end, 5)
          end
        end,
      })
      assert(
        vim.wait(5000, function()
          return called and not view.alive
        end, 5),
        phase .. " close did not finish"
      )
      vim.api.nvim_del_autocmd(hook)
      assert(not next(require("diffreel.lease").buffers), phase .. " left a buffer lease")
      if phase == "normal-pane-error" then
        assert(vim.v.errmsg:find("User hook fixture after close", 1, true), vim.v.errmsg)
        vim.v.errmsg = ""
      else
        assert(vim.v.errmsg == "", vim.v.errmsg)
      end
      assert(vim.api.nvim_buf_is_valid(source), "Close removed incoming real buffer")
      plugin.shutdown()
      vim.api.nvim_buf_delete(source, { force = true })
    end
  end

  plugin.setup({ watch = false })
  local origin = vim.api.nvim_get_current_win()
  local view = plugin.open({ root = root })
  assert(vim.wait(5000, function()
    return view.ready
  end, 5))
  local source = view.right_buf
  local outside = root .. "/outside.txt"
  vim.fn.writefile({ "outside" }, outside)
  local hook = vim.api.nvim_create_autocmd("BufWinEnter", {
    pattern = outside,
    once = true,
    callback = function()
      plugin.close(view)
      vim.schedule(function()
        vim.api.nvim_set_current_win(origin)
      end)
      vim.wait(20, function()
        return false
      end, 5)
    end,
  })
  local loaded = vim.fn.bufadd(outside)
  vim.fn.bufload(loaded)
  assert(
    vim.wait(5000, function()
      return not view.alive
    end, 5),
    "External bufload close did not finish"
  )
  pcall(vim.api.nvim_del_autocmd, hook)
  assert(not next(require("diffreel.lease").buffers), "External bufload close retained a lease")
  plugin.shutdown()
  vim.api.nvim_buf_delete(source, { force = true })
  vim.api.nvim_buf_delete(loaded, { force = true })
  vim.fn.delete(outside)

  for _, caught in ipairs({ false, true }) do
    plugin.setup({ watch = false })
    local view = plugin.open({ root = root })
    local hook = vim.api.nvim_create_autocmd("BufReadPost", {
      pattern = root .. "/a.txt",
      once = true,
      callback = function(args)
        if caught then
          pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
        else
          vim.api.nvim_buf_delete(args.buf, { force = true })
        end
      end,
    })
    assert(
      vim.wait(5000, function()
        return view.error ~= nil
      end, 5),
      "Deleted load buffer did not report an error"
    )
    assert(not view.selection_pending, "Deleted load buffer left selection pending")
    pcall(vim.api.nvim_del_autocmd, hook)
    for buf in pairs(require("diffreel.lease").buffers) do
      assert(vim.api.nvim_buf_is_valid(buf), "Deleted load buffer retained a lease")
    end
    plugin.select(view, "a.txt")
    assert(
      vim.wait(5000, function()
        return view.ready and not view.error
      end, 5),
      "Deleted load buffer could not be retried"
    )
    local source = view.right_buf
    assert(vim.api.nvim_buf_get_lines(source, 0, -1, false)[1] == "new")
    plugin.close(view)
    plugin.shutdown()
    vim.api.nvim_buf_delete(source, { force = true })
  end
end, debug.traceback)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
