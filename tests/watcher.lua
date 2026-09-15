vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local backend
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
local function write(data)
  local file = assert(io.open(root .. "/file.txt", "wb"))
  file:write(data)
  file:close()
end
local function request(method, params)
  local done, result, failure = false, nil, nil
  backend:request(method, params or {}, function(err, value)
    failure, result, done = err, value, true
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 5),
    method .. " timed out"
  )
  assert(not failure, vim.inspect(failure))
  return result
end
local updates, head_notifications = {}, 0
local ok, err = xpcall(function()
  git({ "init", "-q" })
  write("initial\n")
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  backend = require("diffreel.backend.rust").new({ root = root, reconcile_ms = 300 }, function(method, value)
    if method == "comparison/updated" then
      updates[#updates + 1] = value
    end
    if method == "repo/changed" then
      head_notifications = head_notifications + 1
    end
  end)
  request("initialize", { protocol = 4 })
  local comparison = request("comparison/open", { left = "HEAD", right = "worktree", view_id = "one" })
  local id = comparison.comparison_id
  request("view/update", { view_id = "one", comparison_id = id, visible = true, path = "file.txt" })
  write("changed\n")
  assert(
    vim.wait(5000, function()
      local latest = updates[#updates]
      return latest and latest.entries[1] and latest.entries[1].right.content_id == vim.fn.sha256("changed\n")
    end, 10),
    "Live content did not update"
  )
  local first = updates[#updates].generation
  write("another\n")
  assert(
    vim.wait(5000, function()
      local latest = updates[#updates]
      return latest.generation > first and latest.entries[1].right.content_id == vim.fn.sha256("another\n")
    end, 10),
    "M to M content did not update"
  )
  git({ "add", "." })
  git({ "commit", "-qm", "head changed" })
  assert(
    vim.wait(5000, function()
      return head_notifications > 0
    end, 10),
    "HEAD change was not reported"
  )
  local external_ignore = root .. "-ignore"
  vim.fn.writefile({}, external_ignore)
  git({ "config", "core.excludesFile", external_ignore })
  vim.fn.writefile({ "temporary" }, root .. "/scratch.tmp")
  local current = request("comparison/open", { left = "HEAD", view_id = "two" })
  request("view/update", { view_id = "one", comparison_id = id, visible = false })
  updates = {}
  vim.fn.writefile({ "scratch.tmp" }, external_ignore)
  assert(
    vim.wait(5000, function()
      for _, snapshot in ipairs(updates) do
        if snapshot.comparison_id == current.comparison_id and #snapshot.entries == 0 then
          return true
        end
      end
    end, 10),
    "Periodic reconciliation did not recover an event outside the watched roots"
  )
  local timer = false
  for _, job in ipairs(request("debug/metrics").jobs) do
    timer = timer or job.reason == "timer"
  end
  assert(timer, "Lost-event recovery did not run the timer")
  vim.fn.delete(external_ignore)
  request("view/update", { view_id = "two", comparison_id = current.comparison_id, visible = false })
  local count = request("debug/metrics").git_spawns
  vim.wait(750, function()
    return false
  end, 10)
  assert(request("debug/metrics").git_spawns == count, "Hidden view kept reconciling")
  request("shutdown")
end, debug.traceback)
if backend then
  backend:close()
end
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
