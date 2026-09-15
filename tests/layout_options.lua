vim.opt.rtp:prepend(vim.fn.getcwd())
local options = require("diffreel.options")
local input = { explorer = { compact = true, height = 8 } }
local opts = options.normalize({ explorer = { visible = false, mode = "list" } }, input)
assert(
  opts.explorer.visible == false
    and opts.explorer.mode == "list"
    and opts.explorer.compact
    and opts.explorer.height == 8
)
assert(opts.explorer.position == "left")
assert(opts.explorer.full_name == true)
assert(options.explorer({ full_name = false }).full_name == false)
assert(options.explorer({}, { full_name = false }).full_name == false)
opts.explorer.compact = false
assert(input.explorer.compact)
local parsed = options.parse({ "--list", "--compact", "--no-explorer", "--explorer-position=bottom", "--", "src" })
assert(
  parsed.explorer.mode == "list"
    and parsed.explorer.compact
    and not parsed.explorer.visible
    and parsed.explorer.position == "bottom"
)
for _, value in ipairs({
  false,
  { mode = "grid" },
  { position = "center" },
  { height = 0 },
  { width = math.huge },
  { visible = 1 },
  { compact = "yes" },
  { full_name = "yes" },
  { unknown = true },
}) do
  assert(not pcall(options.normalize, { explorer = value }, {}), vim.inspect(value))
end
local calls = 0
local size = function()
  calls = calls + 1
  return 30
end
local dynamic = options.normalize({ explorer = { width = size } }, { explorer = { height = size } })
assert(dynamic.explorer.width == size and dynamic.explorer.height == size and calls == 0)
require("diffreel").setup({ explorer = { width = size, height = size } })
assert(calls == 0, "Setup evaluated a size callback")
for _, value in ipairs({ -1, 1.5, 2147483648, "25%", true }) do
  assert(not pcall(options.explorer, { width = value }))
  assert(not pcall(options.explorer, { height = value }))
end
print("Layout options passed")
vim.cmd("qa!")
