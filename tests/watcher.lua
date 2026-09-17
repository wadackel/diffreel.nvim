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
  backend:close()
  vim.fn.writefile({ "build/" }, root .. "/.gitignore")
  vim.fn.mkdir(root .. "/build", "p")
  git({ "add", ".gitignore" })
  git({ "commit", "-qm", "ignore build" })
  updates = {}
  backend = require("diffreel.backend.rust").new({ root = root, reconcile_ms = 60000 }, function(method, value)
    if method == "comparison/updated" then
      updates[#updates + 1] = value
    end
  end)
  request("initialize", { protocol = 4 })
  local quiet = request("comparison/open", { left = "HEAD", right = "worktree", view_id = "three" })
  request("view/update", { view_id = "three", comparison_id = quiet.comparison_id, visible = true })
  vim.wait(750, function()
    return false
  end, 10)
  local seen, jobs = #updates, #request("debug/metrics").jobs
  vim.fn.writefile({ "object" }, root .. "/build/out.o")
  vim.wait(750, function()
    return false
  end, 10)
  assert(#updates == seen, "An ignored write published a comparison update")
  local metrics = request("debug/metrics").jobs
  for index = jobs + 1, #metrics do
    assert(metrics[index].args[1] ~= "status", "An ignored write reconciled: " .. vim.inspect(metrics[index]))
  end
  write("tracked\n")
  assert(
    vim.wait(5000, function()
      return #updates > seen
    end, 10),
    "A tracked write after an ignored one was not reconciled"
  )
  request("shutdown")
  backend:close()
  vim.fn.mkdir(root .. "/src", "p")
  for index = 0, 199 do
    vim.fn.writefile({ "0" }, root .. "/src/gen" .. index .. ".c")
  end
  git({ "add", "src" })
  git({ "commit", "-qm", "generated sources" })
  write("burst baseline\n")
  local burst_updates = 0
  backend = require("diffreel.backend.rust").new({ root = root, reconcile_ms = 60000 }, function(method)
    if method == "comparison/updated" then
      burst_updates = burst_updates + 1
    end
  end)
  request("initialize", { protocol = 4 })
  local busy = request("comparison/open", { left = "HEAD", right = "worktree", view_id = "four" })
  request("view/update", { view_id = "four", comparison_id = busy.comparison_id, visible = true })
  local blob
  for _, entry in ipairs(busy.entries) do
    if entry.path == "file.txt" and entry.status == "modified" then
      blob = entry.left
    end
  end
  assert(blob and blob.oid, "Burst comparison has no modified file.txt: " .. vim.inspect(busy.entries))
  vim.wait(750, function()
    return false
  end, 10)
  burst_updates = 0
  local written, writer = 0, assert(vim.uv.new_timer())
  local sent, answered, slowest, reader, failures = 0, 0, 0, assert(vim.uv.new_timer()), {}
  local stopped
  writer:start(0, 50, function()
    for _ = 1, 20 do
      local fd = vim.uv.fs_open(root .. "/src/gen" .. written % 200 .. ".c", "w", 420)
      if fd then
        vim.uv.fs_write(fd, tostring(written))
        vim.uv.fs_close(fd)
      end
      written = written + 1
    end
  end)
  reader:start(
    0,
    200,
    vim.schedule_wrap(function()
      local started = vim.uv.hrtime()
      sent = sent + 1
      backend:request("blob/read", { oid = blob.oid, mode = blob.mode }, function(failure)
        failures[#failures + 1] = failure
        answered = answered + 1
        slowest = math.max(slowest, (vim.uv.hrtime() - started) / 1e6)
      end)
    end)
  )
  vim.wait(3000, function()
    return false
  end, 10)
  writer:stop()
  stopped = vim.uv.hrtime()
  local during = burst_updates
  reader:stop()
  writer:close()
  reader:close()
  assert(
    vim.wait(10000, function()
      return answered == sent
    end, 10),
    ("Only %d of %d reads answered during a write burst"):format(answered, sent)
  )
  assert(#failures == 0, vim.inspect(failures))
  assert(sent >= 10 and during > 0, ("Burst sent %d reads with %d updates while writing"):format(sent, during))
  assert(slowest < 5000, ("A read waited %.0f ms during a write burst"):format(slowest))
  request("debug/metrics")
  local settled = (vim.uv.hrtime() - stopped) / 1e6
  assert(settled < 5000, ("The daemon answered %.0f ms after the burst"):format(settled))
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
