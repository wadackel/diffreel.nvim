vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname() .. " repo"
vim.fn.mkdir(root .. "/src", "p")
vim.fn.writefile({ "base" }, root .. "/src/a file.lua")
vim.fn.writefile({ "base" }, root .. "/src/[x]%#\\.lua")
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
end
git({ "init", "-q", "-b", "main" })
git({ "add", "." })
git({ "commit", "-qm", "base" })
git({ "branch", "feature/one" })
git({ "tag", "v1" })
local system, calls = vim.system, {}
vim.system = function(command, opts, callback)
  calls[#calls + 1] = command
  assert(type(callback) == "function", "Completion must query refs asynchronously")
  return system(command, opts, callback)
end
local ok, err = xpcall(function()
  local completion = require("diffreel.completion")
  local function complete(lead, prefix)
    local cmd = "Diffreel --repo " .. vim.fn.fnameescape(root) .. " " .. (prefix or "") .. lead
    return completion.complete(lead, cmd, #cmd)
  end
  assert(vim.tbl_contains(complete("--sta"), "--staged"))
  assert(vim.tbl_contains(complete("--untracked="), "--untracked=no"))
  assert(#calls == 0, "Flag completion spawned Git")
  assert(vim.tbl_contains(complete("src/a", "-- "), "src/a\\ file.lua"))
  assert(vim.tbl_contains(complete("--selected-file=src/a"), "--selected-file=src/a\\ file.lua"))
  local special = complete("--file=src/[")
  assert(vim.deep_equal(special, { "--file=src/[x]%#\\\\.lua" }), vim.inspect(special))
  local received
  vim.api.nvim_create_user_command("DiffreelCompletionArgs", function(args)
    received = args.fargs
  end, { nargs = "*" })
  vim.cmd("DiffreelCompletionArgs " .. special[1] .. " -- " .. complete("src/a", "-- ")[1])
  assert(vim.deep_equal(received, { "--file=src/[x]%#\\.lua", "--", "src/a file.lua" }), vim.inspect(received))
  assert(#calls == 0, "Path completion spawned Git")
  complete("fea")
  assert(#calls == 1 and calls[1][2] == "for-each-ref")
  complete("fea")
  assert(#calls == 1, "Concurrent completion duplicated the ref query")
  assert(
    vim.wait(5000, function()
      return vim.tbl_contains(complete("fea"), "feature/one")
    end, 5),
    "Asynchronous refs did not become available"
  )
  assert(vim.tbl_contains(complete("main...fea"), "main...feature/one"))
  assert(vim.tbl_contains(complete("v"), "v1"))
  assert(vim.tbl_contains(complete(":"), ":0"))
  assert(#calls == 1, "Warm ref completion spawned Git")
  local clear = "DiffreelPRCacheClear "
  assert(vim.deep_equal(completion.complete("", clear, #clear), { "--repo=", "-C" }))
  assert(vim.deep_equal(completion.complete("-", clear .. "-", #clear + 1), { "--repo=", "-C" }))
  require("diffreel").setup({ watch = false })
  local command = vim.api.nvim_get_commands({}).Diffreel
  assert(type(command.complete) == "function", vim.inspect(command))
  assert(vim.tbl_contains(vim.fn.getcompletion("Diffreel --sta", "cmdline"), "--staged"))
  assert(not next(require("diffreel").managers), "Completion started a manager")
  completion.shutdown()
end, debug.traceback)
vim.system = system
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
