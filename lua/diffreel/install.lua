local dist = require("diffreel.distribution")
local M = {}
local active, verified = {}, {}
local sequence = 0

function M.path(spec)
  return vim.fn.stdpath("data") .. "/diffreel/daemon/" .. spec.id .. "/" .. spec.target
end

local function stat(path)
  local value = assert(vim.uv.fs_lstat(path), "Missing installed daemon or verification record")
  assert(value.type == "file", "Installed daemon and record must be regular files")
  return value
end

local function identity(value)
  return table.concat({
    value.dev,
    value.ino,
    value.size,
    value.mode,
    value.mtime.sec,
    value.mtime.nsec,
    value.ctime.sec,
    value.ctime.nsec,
  }, ":")
end

function M.cached(spec)
  local directory = M.path(spec)
  local binary, record = directory .. "/diffreel-daemon", directory .. "/installed.json"
  local ok, result = pcall(function()
    local metadata, receipt = stat(binary), stat(record)
    local key = identity(metadata) .. "/" .. identity(receipt)
    if verified[binary] ~= key then
      local value = vim.json.decode(dist.read(record))
      assert(
        value.build_id == spec.id and value.target == spec.target and value.protocol == dist.protocol,
        "Installed daemon verification record mismatch"
      )
      assert(
        value.size == metadata.size and value.sha256 == vim.fn.sha256(dist.read(binary)),
        "Installed daemon checksum mismatch"
      )
      assert(vim.fn.executable(binary) == 1, "Installed daemon is not executable")
      verified[binary] = key
    end
    return { path = binary, expected = spec }
  end)
  return ok and result or nil, not ok and tostring(result) or nil
end

local function write(path, bytes)
  local file = assert(io.open(path, "wb"))
  local ok, err = file:write(bytes)
  local closed, close_err = file:close()
  assert(ok and closed, err or close_err)
end

local function begin(key, callback)
  local waiter = { done = callback }
  if active[key] then
    active[key].waiters[#active[key].waiters + 1] = waiter
    return active[key], function()
      waiter.done = nil
    end, false
  end
  local request = { waiters = { waiter } }
  active[key] = request
  function request.finish(err, result)
    if active[key] ~= request then
      return
    end
    active[key] = nil
    if request.timer then
      request.timer:stop()
      request.timer:close()
    end
    if request.process then
      pcall(request.process.kill, request.process, 15)
    end
    if request.staging then
      vim.fn.delete(request.staging, "rf")
    end
    for _, waiting in ipairs(request.waiters) do
      if waiting.done then
        waiting.done(err, result)
      end
    end
  end
  function request.guard(fn)
    return function(...)
      if active[key] ~= request then
        return
      end
      local ok, err = pcall(fn, ...)
      if not ok then
        request.finish("diffreel: " .. tostring(err) .. "; retry with :DiffreelInstall or R")
      end
    end
  end
  function request.run(command, done)
    request.process = vim.system(
      command,
      { text = true },
      vim.schedule_wrap(request.guard(function(result)
        request.process = nil
        done(result)
      end))
    )
  end
  request.timer = vim.uv.new_timer()
  request.timer:start(
    120000,
    0,
    vim.schedule_wrap(function()
      request.finish("diffreel: installation timed out after 120 seconds; retry with :DiffreelInstall or R")
    end)
  )
  return request, function()
    waiter.done = nil
  end, true
end

local function probe(request, result, done)
  request.run({ result.path, "--build-info" }, function(response)
    assert(response.code == 0, "Cannot execute daemon --build-info; rebuild or reinstall")
    dist.check_info(vim.json.decode(response.stdout), result.expected)
    done(result)
  end)
end

local function fetch(request, spec, asset, destination, done)
  assert(vim.fn.executable("curl") == 1, "curl is required to download the daemon; install curl and retry")
  request.run({
    "curl",
    "--disable",
    "--proto",
    "=https",
    "--proto-redir",
    "=https",
    "--location",
    "--fail",
    "--silent",
    "--show-error",
    "--connect-timeout",
    "15",
    "--max-time",
    "120",
    "--output",
    destination,
    "--write-out",
    "%{http_code}",
    "https://" .. dist.repository .. "/releases/download/" .. spec.tag .. "/" .. asset,
  }, function(response)
    if response.code == 0 then
      done()
    elseif response.code == 22 then
      error(
        "Cannot download "
          .. spec.tag
          .. " (HTTP "
          .. vim.trim(response.stdout or "unknown")
          .. "); check release availability or pending CI"
      )
    else
      error("Cannot download " .. spec.tag .. "; check network connectivity")
    end
  end)
end

function M.ensure(opts, callback)
  opts = opts or {}
  local custom = not opts.managed and (opts.daemon or vim.g.diffreel_daemon)
  local ok, spec = pcall(function()
    return custom and {} or dist.current()
  end)
  if not ok then
    vim.schedule(function()
      callback(tostring(spec))
    end)
    return function() end
  end
  local key = custom and ("custom:" .. custom) or (spec.id .. "/" .. spec.target)
  local request, cancel, created = begin(key, callback)
  if not created then
    return cancel
  end
  request.guard(function()
    if custom then
      probe(request, { path = custom }, function(result)
        request.finish(nil, result)
      end)
      return
    end
    local cached, cache_error = M.cached(spec)
    if cached then
      probe(request, cached, function(result)
        request.finish(nil, result)
      end)
      return
    end
    assert(
      opts.managed or opts.auto_install ~= false,
      (cache_error or "Daemon is not installed") .. "; automatic installation is disabled"
    )
    local directory = M.path(spec)
    vim.fn.mkdir(directory, "p")
    sequence = sequence + 1
    request.staging =
      assert(vim.uv.fs_mkdtemp(directory .. "/.install-" .. vim.fn.getpid() .. "-" .. sequence .. "-XXXXXX"))
    local binary = request.staging .. "/diffreel-daemon"
    fetch(request, spec, "manifest.json", request.staging .. "/manifest.json", function()
      local manifest = vim.json.decode(dist.read(request.staging .. "/manifest.json"))
      assert(manifest.build_id == spec.id and manifest.protocol == dist.protocol, "Release manifest mismatch")
      local asset = manifest.targets and manifest.targets[spec.target]
      assert(type(asset) == "table" and asset.name == spec.asset, "Release does not contain the required target")
      assert(
        type(asset.size) == "number" and asset.size > 0 and asset.size <= 128 * 1024 * 1024,
        "Invalid release asset size"
      )
      assert(
        type(asset.sha256) == "string" and #asset.sha256 == 64 and asset.sha256:match("^[0-9a-f]+$"),
        "Invalid release checksum"
      )
      fetch(request, spec, spec.asset, binary, function()
        assert(
          stat(binary).size == asset.size and vim.fn.sha256(dist.read(binary)) == asset.sha256,
          "Downloaded daemon checksum mismatch"
        )
        assert(vim.uv.fs_chmod(binary, 493))
        probe(request, { path = binary, expected = spec }, function()
          local record = request.staging .. "/installed.json"
          write(
            record,
            vim.json.encode({
              build_id = spec.id,
              target = spec.target,
              protocol = dist.protocol,
              size = asset.size,
              sha256 = asset.sha256,
            })
          )
          assert(vim.uv.fs_rename(binary, directory .. "/diffreel-daemon"))
          -- Publishing the receipt first could expose an executable whose verification has not completed.
          assert(vim.uv.fs_rename(record, directory .. "/installed.json"))
          verified[directory .. "/diffreel-daemon"] = nil
          request.finish(nil, { path = directory .. "/diffreel-daemon", expected = spec })
        end)
      end)
    end)
  end)()
  return cancel
end

function M.shutdown()
  for _, request in pairs(vim.tbl_extend("force", {}, active)) do
    request.finish("diffreel: installation cancelled during shutdown")
  end
end

return M
