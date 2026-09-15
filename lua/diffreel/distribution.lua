local M = { protocol = 4, repository = "github.com/wadackel/diffreel.nvim" }
local source = debug.getinfo(1, "S").source:sub(2)
M.root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))

function M.read(path)
  local file = assert(io.open(path, "rb"))
  local bytes = assert(file:read("*a"))
  file:close()
  return bytes
end

function M.id(root)
  local paths = {
    ".gitattributes",
    ".deno-version",
    "daemon/Cargo.toml",
    "daemon/Cargo.lock",
    "daemon/build.rs",
    "daemon/rust-toolchain.toml",
    "distribution.json",
    "lua/diffreel/distribution.lua",
    "scripts/build-daemon.sh",
    "scripts/validate-daemon.ts",
  }
  for name, kind in vim.fs.dir(root .. "/daemon/src", { depth = math.huge }) do
    assert(kind == "file" or kind == "directory", "Unsupported build input: " .. name)
    if kind == "file" then
      paths[#paths + 1] = "daemon/src/" .. name
    end
  end
  table.sort(paths)
  local inputs = { "diffreel-daemon-inputs-v1\n" }
  for _, path in ipairs(paths) do
    inputs[#inputs + 1] = #path .. ":" .. path .. ":" .. vim.fn.sha256(M.read(root .. "/" .. path)) .. "\n"
  end
  return vim.fn.sha256(table.concat(inputs))
end

function M.target(host)
  host = host or vim.uv.os_uname()
  local arch = ({ arm64 = "aarch64", aarch64 = "aarch64", x86_64 = "x86_64" })[host.machine]
  local os = ({ Darwin = "apple-darwin", Linux = "unknown-linux-musl" })[host.sysname]
  assert(arch and os, "diffreel: unsupported platform " .. host.sysname .. "/" .. host.machine)
  return arch .. "-" .. os
end

local current
function M.current()
  if not current then
    local id, target = M.id(M.root), M.target()
    current = { id = id, target = target, tag = "daemon-" .. id, asset = "diffreel-daemon-" .. target }
  end
  return vim.deepcopy(current)
end

function M.check_info(info, expected)
  assert(type(info) == "table" and info.protocol == M.protocol, "Daemon protocol mismatch; rebuild or reinstall")
  if expected then
    assert(info.build_id == expected.id, "Daemon build ID mismatch")
    assert(info.target == expected.target, "Daemon target mismatch")
  end
end

return M
