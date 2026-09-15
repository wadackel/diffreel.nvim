vim.opt.rtp:prepend(vim.fn.getcwd())
local lease = require("diffreel.lease")
local buf = vim.api.nvim_get_current_buf()
local view = { id = "one" }
local current, allowed, calls = view, false, 0
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "word text", "two" })
vim.keymap.set("v", "ih", "iw", { buffer = buf })
vim.keymap.set("o", "ih", "iw", { buffer = buf })
local function input(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end
local function action()
  calls = calls + 1
  vim.cmd("normal! V")
end
lease.acquire(
  buf,
  "one",
  function()
    return current
  end,
  {},
  nil,
  {
    x = { actions = { ih = action } },
    o = { actions = { ih = action }, guards = {
      ih = function()
        return allowed
      end,
    } },
  }
)
vim.fn.setreg('"', "keep")
input("yih")
assert(vim.fn.getreg('"') == "keep" and calls == 0, "Ineligible operator was not cancelled")
allowed = true
input("yih")
assert(vim.fn.getreg('"') == "word text\n" and calls == 1)
current = nil
input("0yih")
assert(vim.fn.getreg('"') == "word", "Ordinary operator fallback changed")
vim.keymap.set("s", "ih", "ix", { buffer = buf })
lease.release(buf, "one")
assert(vim.fn.maparg("ih", "x") == "iw" and vim.fn.maparg("ih", "s") == "ix")
assert(vim.fn.maparg("ih", "o") == "iw")
print(vim.json.encode({ passed = true }))
vim.cmd("qa!")
