vim.opt.rtp:prepend(vim.fn.getcwd())

local failures, passed = {}, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
local function eq(expected, actual)
  assert(vim.deep_equal(expected, actual), vim.inspect({ expected = expected, actual = actual }))
end

test("empty content and missing side stay distinct", function()
  local c = require("diffreel.content")
  eq(false, c.decode(nil, "000000").exists)
  eq(true, c.decode("", "100644").exists)
  eq({ "" }, c.decode("", "100644").lines)
  eq(false, c.decode("", "100644").endofline)
  eq(true, c.decode("\n", "100644").endofline)
end)

test("CRLF and final newline metadata survive decoding", function()
  local c = require("diffreel.content")
  local dos = c.decode("a\r\nb\r\n", "100644")
  eq({ "a", "b" }, dos.lines)
  eq("dos", dos.fileformat)
  eq(true, dos.endofline)
  eq({ "a", "b" }, c.decode("a\nb", "100644").lines)
  eq(false, c.decode("a\nb", "100644").endofline)
  eq("mixed-newlines", c.decode("a\r\nb\n", "100644").reason)
end)

test("unsupported data cannot masquerade as an empty text file", function()
  local c = require("diffreel.content")
  eq("binary", c.decode("a\0b", "100644").reason)
  eq("encoding", c.decode(string.char(255), "100644").reason)
  eq("encoding", c.decode(string.char(0xC0, 0x80), "100644").reason)
  eq("encoding", c.decode(string.char(0xED, 0xA0, 0x80), "100644").reason)
  eq("too-large", c.decode("12345", "100644", 4).reason)
  eq("text", c.decode("日本語 🪷", "100644").kind)
end)

test("symlinks compare targets without following them", function()
  local value = require("diffreel.content").decode("../target", "120000")
  eq("symlink", value.kind)
  eq({ "../target" }, value.lines)
end)

test("UTF-8 BOM is metadata rather than an extra first-line character", function()
  local value = require("diffreel.content").decode(string.char(239, 187, 191) .. "first\n", "100644")
  eq({ "first" }, value.lines)
  eq(true, value.bom)
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
