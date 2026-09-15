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
  local result = vim.system(command, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function write(path, data)
  local file = assert(io.open(root .. "/" .. path, "wb"))
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
    "Timed out: " .. method
  )
  assert(not failure, vim.inspect(failure))
  return result
end
local function paths(snapshot)
  local result = {}
  for _, entry in ipairs(snapshot.entries) do
    result[entry.path] = entry
  end
  return result
end

local ok, err = xpcall(function()
  git({ "init", "-q" })
  write("a.txt", "original\n")
  write("other.txt", "other\n")
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  local base = git({ "rev-parse", "HEAD" })
  backend = require("diffreel.backend." .. "rust").new({ root = root, watch = false }, function() end)
  local initialized = request("initialize", { protocol = 4 })
  assert(initialized.head == base)
  write("a.txt", "changed\n")
  local comparison = request("comparison/open", { left = "HEAD", right = "worktree", view_id = "one" })
  local id = comparison.comparison_id
  local snapshot = request("comparison/list", { comparison_id = id })
  assert(paths(snapshot)["a.txt"].status == "modified")
  local before = request("debug/metrics").git_spawns
  for _ = 1, 3 do
    request("comparison/list", { comparison_id = id })
    local content = request("blob/read", { oid = paths(snapshot)["a.txt"].left.oid, mode = "100644" })
    assert(content.lines[1] == "original")
  end
  assert(request("debug/metrics").git_spawns == before, "Warm reads spawned Git")
  write("a.txt", "original\n")
  request("comparison/refresh", { comparison_id = id })
  assert(#request("comparison/list", { comparison_id = id }).entries == 0)
  local clean = request("comparison/file", { comparison_id = id, path = "a.txt" })
  assert(clean.left.content_id == vim.fn.sha256("original\n") and clean.right.content_id == clean.left.content_id)
  assert(clean.left.oid and not clean.left.lines and not clean.right.lines)
  local missing = request("comparison/file", { comparison_id = id, path = "absent.txt" })
  assert(not missing.left.exists and not missing.right.exists)
  for _, path in ipairs({ "../outside.txt", "/absolute.txt", ".git/config", "a\0b" }) do
    local success = pcall(request, "comparison/file", { comparison_id = id, path = path })
    assert(not success, "Accepted an unsafe inspection path")
  end
  assert(#request("comparison/list", { comparison_id = id }).entries == 0, "Inspection changed comparison membership")
  write(".git/info/exclude", "scratch.tmp\n")
  write("scratch.tmp", "ignored draft\n")
  local ignored = request("comparison/file", { comparison_id = id, path = "scratch.tmp" })
  assert(not ignored.left.exists and ignored.right.content_id == vim.fn.sha256("ignored draft\n"))
  assert(#request("comparison/refresh", { comparison_id = id }).entries == 0, "Inspection exposed an ignored path")
  git({ "rm", "--cached", "a.txt" })
  request("comparison/refresh", { comparison_id = id })
  assert(#request("comparison/list", { comparison_id = id }).entries == 0, "Same untracked path is not net-clean")
  write("a.txt", "untracked replacement\n")
  request("comparison/refresh", { comparison_id = id })
  snapshot = request("comparison/list", { comparison_id = id })
  assert(#snapshot.entries == 1 and paths(snapshot)["a.txt"].status == "modified")
  git({ "add", "." })
  git({ "commit", "-qm", "replacement" })
  local newer = git({ "rev-parse", "HEAD" })
  local immutable = request("comparison/open", { left = base, right = newer, view_id = "two" })
  local before_reopen = request("debug/metrics").git_spawns
  request("comparison/open", { left = base, right = newer, view_id = "three" })
  assert(request("debug/metrics").git_spawns == before_reopen, "Reopening fixed revisions spawned Git")
  write("a.txt", "unrelated worktree\n")
  request("comparison/refresh", { comparison_id = immutable.comparison_id })
  snapshot = request("comparison/list", { comparison_id = immutable.comparison_id })
  local right = request("blob/read", { oid = paths(snapshot)["a.txt"].right.oid, mode = "100644" })
  assert(right.lines[1] == "untracked replacement", "Revision comparison followed worktree")
  local fixed = request("comparison/file", { comparison_id = immutable.comparison_id, path = "a.txt" })
  assert(fixed.left.content_id == vim.fn.sha256("original\n"))
  assert(fixed.right.content_id == vim.fn.sha256("untracked replacement\n"))
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
