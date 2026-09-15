vim.opt.rtp:prepend(vim.fn.getcwd())
local system = vim.system
vim.system = function(command, ...)
  assert(command[1] ~= "curl" and command[1] ~= "gh" and command[1] ~= "cargo" and command[1] ~= "nix")
  return system(command, ...)
end
local messages = {}
for _, level in ipairs({ "start", "info", "ok", "warn", "error" }) do
  vim.health[level] = function(message)
    messages[#messages + 1] = message
  end
end
require("diffreel.health").check()
assert(#messages > 0)
assert(table.concat(messages, "\n"):find("curl", 1, true))
assert(not table.concat(messages, "\n"):find("Private release", 1, true))
print("health: passed without network or compiler")
