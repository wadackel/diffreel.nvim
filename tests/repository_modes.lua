vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local engines, cases = {}, {}
local function git(cwd, args, allow_failure)
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
  local result = vim.system(command, { cwd = cwd }):wait()
  assert(allow_failure or result.code == 0, result.stderr)
  return vim.trim(result.stdout)
end
local function write(path, text)
  local file = assert(io.open(path, "wb"))
  file:write(text)
  file:close()
end
local function request(engine, method, params)
  local done, result, failure = false, nil, nil
  engine:request(method, params or {}, function(err, value)
    failure, result, done = err, value, true
  end)
  assert(
    vim.wait(10000, function()
      return done
    end, 5),
    method .. " timeout"
  )
  assert(not failure, vim.inspect(failure))
  return result
end
local function inspect_repository(path, inspect)
  local engine = require("diffreel.backend.rust").new(
    { root = path, watch = false, daemon = vim.env.DIFFREEL_DAEMON },
    function() end
  )
  engines[#engines + 1] = engine
  local init = request(engine, "initialize", { protocol = 4 })
  local snapshot = request(engine, "comparison/open", { view_id = "repository", left = "HEAD" })
  inspect(snapshot, init, engine)
  engine:close()
end
local ok, err = xpcall(function()
  local main = root .. "/main"
  vim.fn.mkdir(main, "p")
  git(main, { "init", "-q", "-b", "main" })
  write(main .. "/a.txt", "base\n")
  git(main, { "add", "." })
  git(main, { "commit", "-qm", "base" })
  local worktree = root .. "/worktree"
  git(main, { "worktree", "add", "--detach", worktree, "HEAD" })
  write(worktree .. "/a.txt", "worktree\n")
  inspect_repository(worktree, function(snapshot, init)
    assert(init.git_dir ~= init.common_dir)
    assert(#snapshot.entries == 1 and snapshot.entries[1].path == "a.txt")
  end)
  assert(git(main, { "status", "--porcelain" }) == "")
  cases[#cases + 1] = "linked worktree isolation"

  local sha = root .. "/sha256"
  vim.fn.mkdir(sha, "p")
  git(sha, { "init", "-q", "--object-format=sha256" })
  write(sha .. "/a.txt", "base\n")
  git(sha, { "add", "." })
  git(sha, { "commit", "-qm", "base" })
  write(sha .. "/a.txt", "changed\n")
  inspect_repository(sha, function(snapshot)
    assert(#snapshot.left == 64 and #snapshot.entries == 1)
  end)
  cases[#cases + 1] = "SHA-256 repository"

  git(main, { "switch", "-c", "other" })
  write(main .. "/a.txt", "other\n")
  git(main, { "commit", "-am", "other" })
  git(main, { "switch", "main" })
  write(main .. "/a.txt", "main\n")
  git(main, { "commit", "-am", "main" })
  git(main, { "merge", "other" }, true)
  inspect_repository(main, function(snapshot)
    assert(#snapshot.entries == 1 and snapshot.entries[1].right.reason == "conflict")
    assert(snapshot.entries[1].git.conflict)
  end)
  cases[#cases + 1] = "unmerged index"

  local super = root .. "/super"
  vim.fn.mkdir(super .. "/sub", "p")
  git(super, { "init", "-q" })
  git(super .. "/sub", { "init", "-q" })
  write(super .. "/sub/a.txt", "base\n")
  git(super .. "/sub", { "add", "." })
  git(super .. "/sub", { "commit", "-qm", "base" })
  write(super .. "/.gitmodules", '[submodule "sub"]\n\tpath = sub\n\turl = ./sub\n')
  git(super, { "add", ".gitmodules", "sub" })
  git(super, { "commit", "-qm", "submodule" })
  write(super .. "/sub/a.txt", "dirty\n")
  inspect_repository(super, function(snapshot)
    assert(#snapshot.entries == 1 and snapshot.entries[1].right.reason == "submodule")
    assert(snapshot.entries[1].left.oid and snapshot.entries[1].git.submodule)
    assert(snapshot.entries[1].git.submodule_state == "S.M.", "Submodule dirty state was lost")
  end)
  cases[#cases + 1] = "submodule metadata"
end, debug.traceback)
for _, engine in ipairs(engines) do
  engine:close()
end
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
local result = { passed = ok, cases = cases }
if vim.env.DIFFREEL_MODES_OUT then
  vim.fn.writefile({ vim.json.encode(result) }, vim.env.DIFFREEL_MODES_OUT)
end
print(vim.json.encode(result))
vim.cmd(ok and "qa!" or "cquit 1")
