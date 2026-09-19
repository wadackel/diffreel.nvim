vim.opt.rtp:prepend(vim.fn.getcwd())
local failures = {}
local scenarios = {
  "delayed",
  "reload",
  "retained-selection",
  "retained-close",
  "retained-navigation",
  "retained-refresh",
  "retained-restart",
  "switching-selection",
  "switching-missing",
  "focus-watch",
  "focus-nowatch",
  "focus-closed",
  "stopped-pending",
}
for _, scenario in ipairs(scenarios) do
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local function write(path, text)
    local file = assert(io.open(root .. "/" .. path, "wb"))
    file:write(text)
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
  local plugin, view
  local ok, err = xpcall(function()
    git({ "init", "-q" })
    write("main.lua", "return 1\n")
    write("other.lua", "return 10\n")
    write("target.lua", "return 'saved'\n")
    git({ "add", "." })
    git({ "commit", "-qm", "baseline" })
    write("main.lua", "return 2\n")
    write("other.lua", "return 20\n")
    plugin = require("diffreel")
    plugin.setup({ backend = "rust", watch = scenario == "focus-watch" or scenario == "focus-closed" })
    view = plugin.open({ root = root })
    assert(vim.wait(5000, function()
      return view.ready
    end, 5))
    local target = vim.fn.bufadd(root .. "/target.lua")
    vim.fn.bufload(target)
    if scenario == "delayed" then
      local backend, callback = view.manager.backend, nil
      local request = backend.request
      backend.request = function(self, method, params, done)
        if method == "blob/read" then
          callback = done
        else
          request(self, method, params, done)
        end
      end
      plugin.select(view, "main.lua")
      assert(callback)
      vim.api.nvim_win_set_buf(view.right_win, target)
      callback(nil, require("diffreel.content").decode("return 1\n", "100644"))
      backend.request = request
      assert(vim.api.nvim_win_get_buf(view.right_win) == target, "Delayed response stole navigation")
    elseif scenario == "stopped-pending" then
      local backend, callback = view.manager.backend, nil
      local request = backend.request
      backend.request = function(self, method, params, done)
        if method == "blob/read" then
          callback = done
        else
          request(self, method, params, done)
        end
      end
      plugin.select(view, "main.lua")
      assert(callback and view.selection_pending)
      local sequence = view.selection_seq
      backend.notify("backend/error", { message = "daemon exited" })
      assert(view.error == "daemon exited" and not view.updating and view.selection_pending)
      local duplicate = vim.deepcopy(view.comparison)
      duplicate.updating, duplicate.error = false, "daemon exited"
      backend.notify("comparison/updated", duplicate)
      assert(view.selection_seq == sequence and view.selection_pending, "A duplicate snapshot restarted the selection")
      backend.request = request
      callback(nil, require("diffreel.content").decode("return 1\n", "100644"))
      assert(
        vim.wait(5000, function()
          return view.ready and not view.selection_pending and view.error == nil
        end, 5),
        "The held selection did not land after the error"
      )
    elseif scenario == "reload" then
      view.by_path["main.lua"].right.content_id = "stale"
      plugin.select(view, "main.lua")
      vim.api.nvim_win_set_buf(view.right_win, target)
      vim.api.nvim_buf_set_lines(target, 0, -1, false, { "return 'unsaved'" })
      vim.wait(60, function()
        return false
      end, 5)
      assert(vim.bo[target].modified, "Scheduled reload discarded the destination draft")
      assert(vim.api.nvim_buf_get_lines(target, 0, 1, false)[1] == "return 'unsaved'")
    elseif scenario == "switching-selection" or scenario == "switching-missing" then
      local selected = scenario == "switching-selection" and "other.lua" or "main.lua"
      if scenario == "switching-missing" then
        plugin.select(view, "other.lua")
        assert(vim.wait(5000, function()
          return view.ready and view.selected_path == "other.lua"
        end, 5))
        git({ "add", "main.lua" })
      else
        write("added.lua", "return 'added'\n")
        git({ "add", "added.lua" })
      end
      git({ "commit", "-qm", "move HEAD" })
      local backend, held = view.manager.backend, nil
      local request = backend.request
      backend.request = function(self, method, params, done)
        if method == "comparison/open" then
          request(self, method, params, function(failure, result)
            held = function()
              done(failure, result)
            end
          end)
        else
          request(self, method, params, done)
        end
      end
      plugin.refresh(view)
      assert(vim.wait(5000, function()
        return held ~= nil
      end, 5))
      backend.request = request
      assert(view.switching)
      plugin.select(view, selected)
      held()
      assert(vim.wait(5000, function()
        return view.ready and not view.switching and not view.selection_pending
      end, 5))
      assert(view.selected_path == "other.lua", "Selection during switching: " .. tostring(view.selected_path))
      assert(vim.fs.basename(vim.api.nvim_buf_get_name(view.right_buf)) == "other.lua")
      assert(view.deferred_path == nil)
    elseif scenario == "focus-watch" or scenario == "focus-nowatch" then
      local backend, methods = view.manager.backend, {}
      local request = backend.request
      backend.request = function(self, method, params, done)
        methods[#methods + 1] = method
        request(self, method, params, done)
      end
      vim.api.nvim_exec_autocmds("FocusGained", {})
      vim.wait(200, function()
        return false
      end, 5)
      backend.request = request
      local expected = scenario == "focus-watch" and { "view/update" } or { "comparison/refresh" }
      assert(vim.deep_equal(methods, expected), "FocusGained requests: " .. vim.inspect(methods))
    elseif scenario == "focus-closed" then
      local manager = view.manager
      manager.backend:close()
      vim.api.nvim_exec_autocmds("FocusGained", {})
      assert(
        vim.wait(5000, function()
          return view.manager ~= manager and view.ready and not view.updating
        end, 5),
        "FocusGained did not restart a closed backend"
      )
    else
      local source, manager = view.right_buf, view.manager
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { "return 'draft'" })
      write("main.lua", "return 1\n")
      local backend, pending = manager.backend, {}
      local request = backend.request
      backend.request = function(self, method, params, done)
        local sequence = view.selection_seq
        request(self, method, params, function(failure, result)
          if method == "comparison/file" then
            pending[#pending + 1] = {
              sequence = sequence,
              done = function()
                done(failure, result)
              end,
            }
          else
            done(failure, result)
          end
        end)
      end
      plugin.refresh(view)
      assert(vim.wait(5000, function()
        return #pending > 0 and pending[#pending].sequence == view.selection_seq and view.selection_pending
      end, 5))
      backend.request = request
      if scenario == "retained-selection" then
        plugin.select(view, "other.lua")
      elseif scenario == "retained-close" then
        plugin.close(view)
      elseif scenario == "retained-navigation" then
        vim.api.nvim_win_set_buf(view.right_win, target)
        vim.api.nvim_buf_set_lines(target, 0, -1, false, { "return 'target draft'" })
      elseif scenario == "retained-refresh" then
        write("main.lua", "return 3\n")
        plugin.refresh(view)
      else
        backend:close()
        plugin.refresh(view)
      end
      if scenario ~= "retained-close" and scenario ~= "retained-navigation" then
        assert(vim.wait(5000, function()
          return view.ready and not view.updating and not view.selection_pending
        end, 5))
      end
      for _, result in ipairs(pending) do
        result.done()
      end
      if scenario == "retained-selection" then
        assert(
          view.selected_path == "other.lua"
            and vim.api.nvim_buf_get_lines(view.right_buf, 0, 1, false)[1] == "return 20"
        )
      elseif scenario == "retained-close" then
        assert(not view.alive and not plugin.views[view.id] and not vim.api.nvim_buf_is_valid(view.left_buf))
        assert(not require("diffreel.lease").buffers[source])
      elseif scenario == "retained-navigation" then
        assert(vim.api.nvim_win_get_buf(view.right_win) == target and vim.bo[target].modified)
        assert(vim.api.nvim_buf_get_lines(target, 0, 1, false)[1] == "return 'target draft'")
        assert(vim.wait(1000, function()
          return view.navigation
        end, 5))
        vim.api.nvim_win_set_buf(view.right_win, source)
        assert(vim.wait(5000, function()
          return view.ready and not view.navigation and not view.selection_pending
        end, 5))
        assert(view.right_buf == source)
      elseif scenario == "retained-refresh" then
        assert(view.by_path["main.lua"].right.content_id == vim.fn.sha256("return 3\n"))
        assert(not view.by_path["main.lua"].buffer_only)
      else
        assert(view.manager ~= manager and view.ready)
        assert(view.by_path["main.lua"].right.content_id == vim.fn.sha256("return 1\n"))
      end
      assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == "return 'draft'")
    end
  end, debug.traceback)
  if view then
    plugin.close(view)
  end
  if plugin then
    plugin.shutdown()
  end
  vim.fn.delete(root, "rf")
  if not ok then
    failures[#failures + 1] = scenario .. ": " .. err
  end
end
for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = #scenarios - #failures, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
