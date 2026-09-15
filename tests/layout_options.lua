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
  { unknown = true },
}) do
  assert(not pcall(options.normalize, { explorer = value }, {}), vim.inspect(value))
end
print("Layout options passed")
vim.cmd("qa!")
