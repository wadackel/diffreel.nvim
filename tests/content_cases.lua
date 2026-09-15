vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local outside = vim.fn.tempname()
local engine, comparison
local cases = {}
local weird = "name[1]%#\t\n.lua"
local function write(path, data)
  local file = assert(io.open(path, "wb"))
  file:write(data)
  file:close()
end
local function git(args, allow_failure)
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
  assert(allow_failure or result.code == 0, result.stderr)
  return vim.trim(result.stdout)
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
    method .. " timed out"
  )
  assert(not failure, vim.inspect(failure))
  return result
end
local function check(name, inspect)
  local snapshot = request(engine, "comparison/refresh", { comparison_id = comparison })
  local entries = {}
  for _, entry in ipairs(snapshot.entries) do
    entries[entry.path] = entry
  end
  inspect(entries)
  cases[#cases + 1] = name
end

local ok, err = xpcall(function()
  git({ "init", "-q" })
  write(root .. "/.gitignore", "ignored/\n*.tracked\n")
  write(root .. "/.gitattributes", "*.crlf text eol=crlf\nfiltered.txt filter=sample\n")
  git({ "config", "filter.sample.clean", "cat" })
  git({ "config", "filter.sample.smudge", "cat" })
  write(root .. "/base.txt", "one\n")
  write(root .. "/bom.ts", string.char(239, 187, 191) .. "export const a = 1;\n")
  write(root .. "/ending.txt", "one\n")
  write(root .. "/binary.bin", "a\0b")
  write(root .. "/large.txt", string.rep("a", 1048577))
  write(root .. "/filtered.txt", "one\n")
  write(root .. "/clean.crlf", "same\r\n")
  write(root .. "/keep.tracked", "one\n")
  write(root .. "/日本.lua", "return 1\n")
  write(root .. "/" .. weird, "return 1\n")
  write(outside, "outside payload must not be read")
  assert(vim.uv.fs_symlink(outside, root .. "/link"))
  git({ "add", "." })
  git({ "add", "-f", "keep.tracked" })
  git({ "commit", "-qm", "baseline" })
  engine = require("diffreel.backend.rust").new(
    { root = root, watch = false, daemon = vim.env.DIFFREEL_DAEMON },
    function() end
  )
  request(engine, "initialize", { protocol = 4 })
  comparison = request(engine, "comparison/open", { view_id = "content", left = "HEAD" }).comparison_id
  write(root .. "/base.txt", "two\n")
  write(root .. "/bom.ts", string.char(239, 187, 191) .. "export const a = 2;\n")
  write(root .. "/ending.txt", "one")
  write(root .. "/binary.bin", "c\0d")
  write(root .. "/large.txt", string.rep("b", 1048577))
  write(root .. "/filtered.txt", "two\n")
  write(root .. "/empty.txt", "")
  write(root .. "/keep.tracked", "two\n")
  write(root .. "/日本.lua", "return 2\n")
  write(root .. "/" .. weird, "return 2\n")
  vim.fn.mkdir(root .. "/ignored", "p")
  write(root .. "/ignored/noise.txt", "ignored\n")
  vim.fn.delete(root .. "/link")
  assert(vim.uv.fs_symlink(outside .. "-missing", root .. "/link"))
  check("text and limited content", function(e)
    assert(e["base.txt"].status == "modified")
    assert(e["bom.ts"].left.bom and e["bom.ts"].right.bom)
    assert(e["ending.txt"].left.endofline and not e["ending.txt"].right.endofline)
    assert(e["empty.txt"].status == "added" and e["empty.txt"].right.size == 0)
    assert(e["binary.bin"].right.reason == "binary")
    assert(e["large.txt"].right.reason == "too-large")
    assert(e["filtered.txt"].right.reason == "filter")
    assert(e["keep.tracked"] and not e["ignored/noise.txt"] and not e["clean.crlf"])
    assert(e["日本.lua"] and e[weird])
    assert(e.link.left.kind == "symlink" and e.link.right.kind == "symlink")
  end)
  write(root .. "/base.txt", "one\n")
  git({ "mv", "base.txt", "renamed.txt" })
  write(root .. "/base.txt", "replacement\n")
  check("rename source reappears", function(e)
    assert(e["base.txt"].status == "modified" and e["renamed.txt"].status == "added")
  end)
  vim.fn.delete(root .. "/base.txt")
  check("rename endpoints", function(e)
    assert(e["renamed.txt"].old_path == "base.txt" and e["renamed.txt"].status == "renamed")
    assert(not e["base.txt"])
  end)
  vim.fn.delete(root .. "/日本.lua")
  check("deleted side is absent", function(e)
    assert(e["日本.lua"].status == "deleted" and not e["日本.lua"].right.exists)
  end)
  write(root .. "/日本.lua", "return 1\n")
  check("recreated identical file disappears", function(e)
    assert(not e["日本.lua"])
  end)
  vim.fn.delete(root .. "/ending.txt")
  assert(vim.uv.fs_symlink(outside, root .. "/ending.txt"))
  check("regular file to symlink", function(e)
    assert(e["ending.txt"].status == "typechange" and e["ending.txt"].right.kind == "symlink")
  end)
end, debug.traceback)
if engine then
  engine:close()
end
vim.fn.delete(root, "rf")
vim.fn.delete(outside)
if not ok then
  io.stderr:write(err .. "\n")
end
local result = { passed = ok, cases = cases }
if vim.env.DIFFREEL_PARITY_OUT then
  vim.fn.writefile({ vim.json.encode(result) }, vim.env.DIFFREEL_PARITY_OUT)
end
print(vim.json.encode(result))
vim.cmd(ok and "qa!" or "cquit 1")
