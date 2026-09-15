vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.diffreel_daemon = nil
local data = vim.fn.tempname()
vim.env.XDG_DATA_HOME = data
local dist = require("diffreel.distribution")
local install = require("diffreel.install")
local spec = { id = string.rep("a", 64), target = dist.target() }
spec.tag, spec.asset = "daemon-" .. spec.id, "diffreel-daemon-" .. spec.target
dist.current = function()
  return vim.deepcopy(spec)
end
local info = { protocol = 4, build_id = spec.id, target = spec.target, version = "0.1.0" }
local bytes = "#!/bin/sh\nprintf '%s\\n' '" .. vim.json.encode(info) .. "'\n"
local manifest = { build_id = spec.id, protocol = 4, targets = {} }
manifest.targets[spec.target] = { name = spec.asset, size = #bytes, sha256 = vim.fn.sha256(bytes) }
local system, executable, calls, mode, delayed = vim.system, vim.fn.executable, {}, "public", {}
local tools = { curl = true, gh = true }
vim.fn.executable = function(command)
  if tools[command] ~= nil then
    return tools[command] and 1 or 0
  end
  return executable(command)
end
vim.system = function(command, opts, callback)
  if command[1] ~= "curl" and command[1] ~= "gh" then
    return system(command, opts, callback)
  end
  calls[#calls + 1] = { command = command, opts = opts }
  local process = { killed = false }
  function process:kill()
    self.killed = true
  end
  local function complete()
    if process.killed then
      callback({ code = 143, stdout = "" })
      return
    end
    if mode == "offline" or mode:match("^http:") then
      callback({ code = mode == "offline" and 6 or 22, stdout = mode:match("^http:(%d+)$") or "000" })
      return
    end
    local destination, asset
    for i, arg in ipairs(command) do
      if arg == "--output" then
        destination = command[i + 1]
      elseif arg == "--pattern" then
        asset = command[i + 1]
      end
    end
    asset = asset or command[#command]:match("/([^/]+)$")
    local file = assert(io.open(destination, "wb"))
    file:write(asset == "manifest.json" and vim.json.encode(manifest) or bytes)
    file:close()
    callback({ code = 0, stdout = "200" })
  end
  if mode == "delayed" then
    delayed[#delayed + 1] = complete
  else
    vim.schedule(complete)
  end
  return process
end

local function ensure(opts)
  local done, err, result
  install.ensure(opts or {}, function(e, r)
    done, err, result = true, e, r
  end)
  assert(
    vim.wait(5000, function()
      return done
    end),
    "installer timed out"
  )
  return err, result
end

local directory = install.path(spec)
vim.fn.delete(vim.fs.dirname(directory), "rf")
assert(ensure({ auto_install = false }), "disabled automatic installation must fail on a miss")
assert(#calls == 0)
local err, result = ensure()
assert(not err, err)
assert(result.path == directory .. "/diffreel-daemon")
assert(#calls == 2)
assert(not ensure({ auto_install = false }))
assert(#calls == 2, "cache hit must not need network")
vim.fn.writefile({ "corrupt" }, result.path)
assert(ensure({ auto_install = false }), "corrupt cache must not execute offline")
for _, status in ipairs({ "401", "403", "404", "500" }) do
  mode = "http:" .. status
  local before = #calls
  local failure = ensure()
  assert(failure and failure:find("HTTP " .. status, 1, true), "HTTP failure must report its status")
  assert(#calls == before + 1, "HTTP failures must not try another download tool")
  assert(calls[#calls].command[1] == "curl")
end
mode = "public"
assert(not ensure(), "retry must install the public release")
for _, call in ipairs(calls) do
  assert(call.command[1] == "curl", "managed downloads must use anonymous HTTPS")
  assert(call.command[#call.command]:find("https://github.com/wadackel/diffreel.nvim/releases/download/", 1, true))
end
tools.curl = false
assert(not ensure({ auto_install = false }), "verified cache must work without curl")
vim.fn.delete(directory .. "/installed.json")
assert(ensure({ auto_install = false }), "a binary without its verification record is incomplete")
local before = #calls
local unavailable = ensure()
assert(unavailable and unavailable:find("curl is required", 1, true), "missing curl must be reported")
assert(#calls == before, "missing curl must not fall back to gh")
tools.curl = true
mode = "offline"
local offline = ensure()
assert(offline and offline:find("network connectivity", 1, true))
mode = "public"
manifest.targets[spec.target].sha256 = string.rep("b", 64)
assert(ensure(), "bad checksum must fail")
manifest.targets[spec.target].sha256 = vim.fn.sha256(bytes)
mode = "delayed"
local completed = 0
local cancel = install.ensure({}, function(e)
  assert(not e, e)
  completed = completed + 1
end)
install.ensure({}, function(e)
  assert(not e, e)
  completed = completed + 1
end)
assert(#delayed == 1, "same-editor installs must coalesce")
cancel()
mode = "public"
delayed[1]()
assert(vim.wait(5000, function()
  return completed == 1
end))
local good_manifest = vim.deepcopy(manifest)
local good_bytes = bytes
for _, corrupt in ipairs({
  function()
    manifest.protocol = 99
  end,
  function()
    manifest.build_id = string.rep("c", 64)
  end,
  function()
    manifest.targets = {}
  end,
  function()
    manifest.targets[spec.target].name = "../unexpected"
  end,
  function()
    manifest.targets[spec.target].size = -1
  end,
  function()
    local wrong = vim.tbl_extend("force", info, { target = "wrong-target" })
    bytes = "#!/bin/sh\nprintf '%s\\n' '" .. vim.json.encode(wrong) .. "'\n"
    manifest.targets[spec.target].size = #bytes
    manifest.targets[spec.target].sha256 = vim.fn.sha256(bytes)
  end,
  function()
    local wrong = vim.tbl_extend("force", info, { build_id = "local" })
    bytes = "#!/bin/sh\nprintf '%s\\n' '" .. vim.json.encode(wrong) .. "'\n"
    manifest.targets[spec.target].size = #bytes
    manifest.targets[spec.target].sha256 = vim.fn.sha256(bytes)
  end,
}) do
  vim.fn.delete(directory, "rf")
  corrupt()
  assert(ensure(), "invalid artifact was accepted")
  assert(not vim.uv.fs_stat(directory .. "/installed.json"))
  manifest, bytes = vim.deepcopy(good_manifest), good_bytes
end
local new_timer, expire = vim.uv.new_timer, nil
vim.uv.new_timer = function()
  return {
    start = function(_, milliseconds, _, callback)
      assert(milliseconds == 120000)
      expire = callback
    end,
    stop = function() end,
    close = function() end,
  }
end
mode = "delayed"
local timeout_error
install.ensure({}, function(e)
  timeout_error = e
end)
vim.uv.new_timer = new_timer
expire()
assert(vim.wait(1000, function()
  return timeout_error ~= nil
end))
assert(timeout_error:find("timed out", 1, true))
local old_completion = delayed[#delayed]
local cancelled
install.ensure({}, function(e)
  cancelled = e
end)
install.shutdown()
assert(cancelled)
mode = "public"
assert(not ensure())
old_completion()
delayed[#delayed]()
vim.wait(50, function()
  return false
end)
assert(not ensure({ auto_install = false }), "obsolete completions damaged a newer installation")
local custom = directory .. "/diffreel-daemon"
dist.current = function()
  error("source files are unavailable")
end
assert(not ensure({ daemon = custom, auto_install = false }), "custom binaries must not hash sources")
vim.g.diffreel_daemon = "/does-not-exist/diffreel-daemon"
assert(not ensure({ daemon = custom }), "explicit options must override the global path")
assert(ensure({ auto_install = false }), "a broken explicit path must not fall back to the cache")
vim.system = system
vim.fn.executable = executable
install.shutdown()
vim.fn.delete(vim.fs.dirname(directory), "rf")
print("installer: passed")
vim.fn.delete(data, "rf")
