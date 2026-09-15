vim.opt.rtp:prepend(vim.fn.getcwd())
local dist = require("diffreel.distribution")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.mkdir(root .. "/daemon", "p")
vim.fn.system({ "cp", "-R", "lua", "scripts", "distribution.json", ".gitattributes", ".deno-version", root })
assert(vim.v.shell_error == 0)
vim.fn.system({
  "cp",
  "-R",
  "daemon/src",
  "daemon/Cargo.toml",
  "daemon/Cargo.lock",
  "daemon/build.rs",
  "daemon/rust-toolchain.toml",
  root .. "/daemon",
})
assert(vim.v.shell_error == 0)
local id = dist.id(root)
assert(id:match("^[0-9a-f]+$") and #id == 64)
local original = dist.read(root .. "/daemon/src/main.rs")
vim.fn.writefile({ "UI change" }, root .. "/lua/diffreel/init.lua")
assert(dist.id(root) == id, "UI-only edits must reuse the daemon")
vim.fn.writefile({ "test dependency change" }, root .. "/deno.lock")
assert(dist.id(root) == id, "Test dependencies must not rebuild the daemon")
for _, path in ipairs({ "version.txt", "CHANGELOG.md", "release-please-config.json", ".release-please-manifest.json" }) do
  vim.fn.writefile({ "plugin release metadata" }, root .. "/" .. path)
  assert(dist.id(root) == id, "Plugin versioning must not rebuild the daemon: " .. path)
end
for _, path in ipairs({ "scripts/validate-daemon.ts", ".deno-version" }) do
  local previous = dist.read(root .. "/" .. path)
  vim.fn.writefile({ "" }, root .. "/" .. path, "a")
  assert(dist.id(root) ~= id, "Validation inputs must change the identity: " .. path)
  local restored = assert(io.open(root .. "/" .. path, "wb"))
  restored:write(previous)
  restored:close()
  assert(dist.id(root) == id)
end
vim.fn.writefile({ "" }, root .. "/daemon/src/main.rs", "a")
assert(dist.id(root) ~= id, "Rust edits must change the identity")
local file = assert(io.open(root .. "/daemon/src/main.rs", "wb"))
file:write(original)
file:close()
assert(dist.id(root) == id, "rollback must restore the identity without Git history")
assert(vim.uv.fs_rename(root .. "/daemon/src/main.rs", root .. "/daemon/src/renamed.rs"))
assert(dist.id(root) ~= id, "input paths must participate in the identity")
assert(dist.target({ sysname = "Darwin", machine = "arm64" }) == "aarch64-apple-darwin")
assert(dist.target({ sysname = "Darwin", machine = "x86_64" }) == "x86_64-apple-darwin")
assert(dist.target({ sysname = "Linux", machine = "aarch64" }) == "aarch64-unknown-linux-musl")
assert(dist.target({ sysname = "Linux", machine = "x86_64" }) == "x86_64-unknown-linux-musl")
assert(not pcall(dist.target, { sysname = "Windows_NT", machine = "AMD64" }))
local current = dist.current()
assert(current.id == dist.id(vim.fn.getcwd()))
assert(current.tag == "daemon-" .. current.id)
vim.fn.delete(root, "rf")
print("distribution: passed")
