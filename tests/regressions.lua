vim.opt.rtp:prepend(vim.fn.getcwd())
local failures, passed = {}, 0
local function test(name, body)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  local backend
  local snapshots = {}
  local tools_dir = root .. "-tools"
  local function write(path, data)
    local file = assert(io.open(root .. "/" .. path, "wb"))
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
    return vim.trim(result.stdout)
  end
  local function request(method, params, allow_error)
    local done, result, failure = false, nil, nil
    backend:request(method, params or {}, function(err, value)
      failure, result, done = err, value, true
    end)
    assert(
      vim.wait(5000, function()
        return done
      end, 5),
      "Timed out: " .. method
    )
    if not allow_error then
      assert(not failure, vim.inspect(failure))
    end
    return result, failure
  end
  local function start(watch)
    backend = require("diffreel.backend.rust").new(
      { root = root, watch = watch, reconcile_ms = 10000 },
      function(method, value)
        if method == "comparison/updated" then
          snapshots[value.comparison_id] = value
        end
      end
    )
    request("initialize", { protocol = 4 })
    return backend
  end
  local ok, err = xpcall(function()
    git({ "init", "-q" })
    body({
      root = root,
      tools_dir = tools_dir,
      snapshots = snapshots,
      write = write,
      git = git,
      request = request,
      start = start,
      new = function()
        backend = require("diffreel.backend.rust").new({ root = root }, function() end)
        return backend
      end,
    })
  end, debug.traceback)
  if backend then
    backend:close()
  end
  vim.fn.delete(root, "rf")
  vim.fn.delete(tools_dir, "rf")
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end

test("partial events never introduce Git-clean CRLF entries", function(t)
  t.write(".gitattributes", "*.txt text eol=crlf\n")
  t.write("a.txt", "same\r\n")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "baseline" })
  local b = t.start(true)
  local c = t.request("comparison/open", { view_id = "a", left = "HEAD" })
  assert(#c.entries == 0)
  t.write("a.txt", "same\r\n")
  assert(vim.wait(2000, function()
    return t.snapshots[c.comparison_id] and t.snapshots[c.comparison_id].generation > c.generation
  end, 10))
  assert(#t.request("comparison/list", { comparison_id = c.comparison_id }).entries == 0)
end)

test("hidden comparisons catch up while another comparison stays visible", function(t)
  t.write("a.txt", "one\n")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "one" })
  local old = t.git({ "rev-parse", "HEAD" })
  t.write("a.txt", "two\n")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "two" })
  local b = t.start(true)
  local a = t.request("comparison/open", { view_id = "a", left = old })
  local other = t.request("comparison/open", { view_id = "b", left = "HEAD" })
  t.request("view/update", { view_id = "a", comparison_id = a.comparison_id, visible = false })
  t.write("a.txt", "three\n")
  assert(vim.wait(2000, function()
    return t.snapshots[other.comparison_id] and t.snapshots[other.comparison_id].generation > other.generation
  end, 10))
  t.request("view/update", { view_id = "a", comparison_id = a.comparison_id, visible = true })
  assert(
    vim.wait(2000, function()
      local snapshot = t.snapshots[a.comparison_id]
      local entry = snapshot and snapshot.entries[1]
      return entry and entry.right.content_id == vim.fn.sha256("three\n")
    end, 10),
    "Reopened comparison retained stale content"
  )
end)

test("frozen empty baseline survives the first commit", function(t)
  t.write("a.txt", "one\n")
  t.start(false)
  local c = t.request("comparison/open", { view_id = "a", left = "HEAD" })
  assert(#c.entries == 1)
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "first" })
  local value = t.request("comparison/refresh", { comparison_id = c.comparison_id })
  assert(#value.entries == 1 and value.entries[1].status == "added")
end)

test("new fixed comparisons resolve the current HEAD", function(t)
  t.write("a.txt", "one\n")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "one" })
  local old = t.git({ "rev-parse", "HEAD" })
  t.start(false)
  t.write("a.txt", "two\n")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "two" })
  local current = t.git({ "rev-parse", "HEAD" })
  local c = t.request("comparison/open", { view_id = "a", left = old, right = "HEAD" })
  assert(c.right == current and #c.entries == 1)
end)

test("an invalidation during refresh survives hiding the comparison", function(t)
  t.write("a.txt", "one\n")
  t.write("b.txt", "one\n")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "one" })
  local old = t.git({ "rev-parse", "HEAD" })
  t.write("a.txt", "two\n")
  t.write("b.txt", "two\n")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "two" })
  vim.fn.mkdir(t.tools_dir, "p")
  local gate, entered = t.tools_dir .. "/gate", t.tools_dir .. "/entered"
  local real_git = vim.fn.exepath("git")
  local script = {
    "#!/bin/sh",
    "exec " .. vim.fn.shellescape(vim.fn.exepath("deno")) .. " run --no-config -A " .. vim.fn.shellescape(
      vim.fn.getcwd() .. "/tests/git_refresh_fixture.ts"
    ) .. " " .. vim.fn.shellescape(real_git) .. " " .. vim.fn.shellescape(gate) .. " " .. vim.fn.shellescape(
      entered
    ) .. ' "$@"',
  }
  vim.fn.writefile(script, t.tools_dir .. "/git")
  assert(vim.uv.fs_chmod(t.tools_dir .. "/git", 493))
  local path = vim.env.PATH
  vim.env.PATH = t.tools_dir .. ":" .. path
  local b = t.start(true)
  vim.env.PATH = path
  local a = t.request("comparison/open", { view_id = "a", left = old })
  t.request("comparison/open", { view_id = "b", left = "HEAD" })
  vim.fn.writefile({}, gate)
  local refreshed
  b:request("comparison/refresh", { comparison_id = a.comparison_id }, function(failure)
    assert(not failure, failure)
    refreshed = true
  end)
  assert(vim.wait(5000, function()
    return vim.uv.fs_stat(entered) ~= nil
  end, 10))
  t.write("a.txt", "three\n")
  b:request("view/update", { view_id = "a", comparison_id = a.comparison_id, visible = false }, function() end)
  vim.fn.delete(gate)
  assert(vim.wait(5000, function()
    return refreshed
  end, 10))
  t.request("view/update", { view_id = "a", comparison_id = a.comparison_id, visible = true })
  assert(
    vim.wait(5000, function()
      local snapshot = t.snapshots[a.comparison_id]
      return snapshot and snapshot.entries[1].right.content_id == vim.fn.sha256("three\n")
    end, 10),
    "New invalidation was cleared by older refresh"
  )
end)

test("initialization failure can be retried after index repair", function(t)
  t.write("a.txt", "one\n")
  t.git({ "add", "." })
  t.git({ "commit", "-qm", "one" })
  local f = assert(io.open(t.root .. "/.git/index", "rb"))
  local original = f:read("*a")
  f:close()
  t.write(".git/index", "broken")
  t.new()
  local _, failure = t.request("initialize", { protocol = 4 }, true)
  assert(failure)
  t.write(".git/index", original)
  t.request("initialize", { protocol = 4 })
end)

for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
