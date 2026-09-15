vim.opt.rtp:prepend(vim.fn.getcwd())
local explorer = require("diffreel.explorer")
local icon, group
package.loaded["nvim-web-devicons"] = {
  get_icon = function()
    return icon, group
  end,
}
local failures, passed = {}, 0
local function test(name, path, before, change)
  vim.wo.listchars = "tab:>-,trail:."
  vim.wo.fillchars = "vert:|,horiz:-"
  vim.fn.setcellwidths({})
  vim.o.ambiwidth = "single"
  vim.o.emoji = true
  vim.o.isprint = "@,161-255"
  vim.o.display = "lastline"
  vim.bo.tabstop, vim.bo.vartabstop = 8, ""
  vim.wo.list = false
  vim.o.arabicshape, vim.o.termbidi = true, false
  icon, group = nil, nil
  local ok, err = pcall(function()
    if before then
      before()
    end
    local entries = { { path = path, status = "modified" } }
    local tree = explorer.build(entries)
    explorer.rows(entries, {}, 24, tree)
    change()
    local reused = explorer.rows(entries, {}, 24, tree)
    local fresh = explorer.rows(entries, {}, 24)
    assert(vim.deep_equal(reused, fresh), "Cached display differs from a fresh render")
  end)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end

test("updated icon", "file.lua", function()
  icon, group = "A", "IconA"
end, function()
  icon = "界"
end)
test("updated icon group", "file.lua", function()
  icon, group = "A", "IconA"
end, function()
  group = "IconB"
end)
test("new icon", "file.lua", nil, function()
  icon, group = "A", "IconA"
end)
test("ambiwidth", "αααααααααα.lua", nil, function()
  vim.o.ambiwidth = "double"
end)
test("cell widths", "αααααααααα.lua", nil, function()
  vim.fn.setcellwidths({ { 0x3b1, 0x3b1, 2 } })
end)
test("isprint", "éééééééééé.lua", nil, function()
  vim.o.isprint = "@,161-255,^233"
end)
test("display", "file.lua", function()
  icon = "\1"
end, function()
  vim.o.display = "lastline,uhex"
end)
test("tabstop", "file.lua", function()
  icon = "\t"
end, function()
  vim.bo.tabstop = 4
end)
test("vartabstop", "file.lua", function()
  icon = "\t"
end, function()
  vim.bo.vartabstop = "4,8"
end)
test("list", "file.lua", function()
  icon = "\t"
  vim.wo.listchars = "trail:."
end, function()
  vim.wo.list = true
end)
test("listchars", "file.lua", function()
  icon = "\t"
  vim.wo.list = true
end, function()
  vim.wo.listchars = "trail:."
end)
test("arabicshape", "لالالالالالا.lua", nil, function()
  vim.o.arabicshape = false
end)
test("termbidi", "لالالالالالا.lua", nil, function()
  vim.o.termbidi = true
end)
test("emoji", string.rep(vim.fn.nr2char(0x1f321), 10) .. ".lua", nil, function()
  vim.o.emoji = false
end)
for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
