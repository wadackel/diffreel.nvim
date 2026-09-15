local M = {}

function M.check()
  local health = vim.health
  local dist = require("diffreel.distribution")
  local config = require("diffreel").config
  health.start("diffreel")
  if vim.fn.has("nvim-0.12") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.12 or newer is required")
  end
  local inline, reason = require("diffreel.inline").check()
  if inline then
    health.ok("Inline layout: window-scoped namespaces and current diff options are supported")
  else
    health.warn("Inline layout unavailable: " .. reason, { "Use side_by_side or stacked; see :help diffreel-inline" })
  end
  if vim.fn.executable("git") == 1 then
    local git = vim.system({ "git", "--version" }, { text = true }):wait(5000)
    health.info(vim.trim(git.stdout or "git version unavailable"))
  else
    health.error("Git 2.55 or newer is required")
  end
  health.info("Automatic installation: " .. tostring(config.auto_install ~= false))
  local binary = config.daemon or vim.g.diffreel_daemon
  local expected
  if not binary then
    local ok, spec = pcall(dist.current)
    if not ok then
      health.error(tostring(spec))
      return
    end
    expected = spec
    health.info("Build " .. spec.id .. ", target " .. spec.target)
    local cached, err = require("diffreel.install").cached(spec)
    if not cached then
      health.warn("Daemon not ready: " .. err, { "Run :DiffreelInstall to prepare it" })
    else
      binary = cached.path
    end
  end
  if binary then
    health.info("Executable: " .. binary)
    local ok, err = pcall(function()
      local result = vim.system({ binary, "--build-info" }, { text = true }):wait(5000)
      assert(result.code == 0, "Cannot run --build-info")
      local info = vim.json.decode(result.stdout)
      dist.check_info(info, expected)
      health.ok("Daemon " .. info.version .. " (" .. info.build_id .. ")")
    end)
    if not ok then
      health.error(tostring(err))
    end
  end
  for _, command in ipairs({ "curl", "gh" }) do
    health.info(command .. ": " .. (vim.fn.executable(command) == 1 and "available" or "unavailable"))
  end
  health.info("Managed daemon downloads require curl. This check does not access the network.")
  health.info("GitHub PR review requires an authenticated gh. Local revision/worktree reviews do not require gh.")
end

return M
