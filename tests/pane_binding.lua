vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.columns, vim.o.lines = 120, 30
local plugin = require("diffreel")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function git(args)
  local command = {
    "git",
    "-c",
    "user.name=Example",
    "-c",
    "user.email=example@example.invalid",
    "-c",
    "commit.gpgsign=false",
    "-c",
    "core.hooksPath=/dev/null",
  }
  vim.list_extend(command, args)
  local result = vim.system(command, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
end
local function lines(tag)
  local result = {}
  for i = 1, 200 do
    result[i] = ("%s %03d "):format(i % 7 == 0 and tag or "same", i) .. ("abcdefghij"):rep(25)
  end
  return result
end
git({ "init", "-qb", "main" })
vim.fn.writefile(lines("old"), root .. "/a.txt")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile(lines("new"), root .. "/a.txt")
local function input(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end
local ok, err = xpcall(function()
  plugin.setup({ watch = false })
  local v = plugin.open({ root = root })
  local function settled()
    assert(vim.wait(10000, function()
      return v.error or (v.ready and not v.layout_pending)
    end, 5))
    assert(not v.error, v.error)
  end
  local function bound(label)
    local left = vim.api.nvim_win_call(v.left_win, vim.fn.winsaveview)
    local right = vim.api.nvim_win_call(v.right_win, vim.fn.winsaveview)
    assert(
      left.topline == right.topline and left.leftcol == right.leftcol,
      ("%s: left %d/%d, right %d/%d"):format(label, left.topline, left.leftcol, right.topline, right.leftcol)
    )
    return right
  end
  settled()
  for _, layout in ipairs({ "side_by_side", "stacked" }) do
    plugin.set_layout(v, layout)
    settled()
    for _, side in ipairs({ "right", "left" }) do
      local label = layout .. " " .. side
      vim.api.nvim_set_current_win(v[side .. "_win"])
      input("gg040zl")
      assert(bound(label .. " scrolled").leftcol == 40)
      input("]H")
      local last = bound(label .. " last hunk")
      assert(last.lnum == 196 and last.topline > 1 and last.leftcol == 0)
      input("40zl[H")
      local first = bound(label .. " first hunk")
      assert(first.lnum == 7 and first.topline <= 7 and first.leftcol == 0)
    end
  end
  plugin.close(v)
end, debug.traceback)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
