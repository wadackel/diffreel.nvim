vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = require("diffreel")
local options = require("diffreel.options")
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
git({ "init", "-qb", "main" })
vim.fn.writefile({ "before", "same", "removed", "tail" }, root .. "/a.txt")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile({ "after", "same", "tail" }, root .. "/a.txt")
local function ready(v)
  assert(vim.wait(10000, function()
    return v.error or (v.ready and not v.inline_pending and not v.layout_pending)
  end, 5))
  assert(not v.error, v.error)
end
local ok, err = xpcall(function()
  assert(options.normalize({}).layout == "side_by_side")
  assert(options.parse({ "--layout=stacked" }).layout == "stacked")
  assert(not pcall(options.normalize, { layout = "bad" }))
  assert(options.parse({ "--layout", "inline" }).layout == "inline")
  plugin.setup({ watch = false })
  local events = {}
  vim.api.nvim_create_autocmd("User", {
    pattern = { "DiffreelLayoutChanged", "DiffreelDiffBufRead", "DiffreelReady" },
    callback = function(event)
      local observed = { name = event.match, data = event.data }
      events[#events + 1] = observed
      if event.match == "DiffreelReady" then
        local current = plugin.get_view(event.data.view_id)
        observed.current = current.layout ~= "inline" or require("diffreel.inline").current(current)
      end
    end,
  })
  local v = plugin.open({ root = root, layout = "stacked" })
  ready(v)
  assert(vim.api.nvim_win_get_position(v.left_win)[1] < vim.api.nvim_win_get_position(v.right_win)[1])
  local buf, win = v.right_buf, v.right_win
  vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "draft" })
  plugin.set_layout(v, "inline")
  ready(v)
  assert(v.layout == "inline" and v.right_buf == buf and v.right_win == win)
  local changed = vim.tbl_filter(function(event)
    return event.name == "DiffreelLayoutChanged" and event.data.previous_layout == "stacked"
  end, events)
  assert(#changed == 1 and changed[1].data.layout == "inline")
  plugin.select(v, "a.txt")
  ready(v)
  local reads = vim.tbl_filter(function(event)
    return event.name == "DiffreelDiffBufRead" and event.data.layout == "inline"
  end, events)
  assert(#reads == 2 and not reads[1].data.visible and reads[1].data.winid == nil)
  assert(reads[2].data.visible and reads[2].data.winid == win)
  assert(not vim.wo[win].diff and vim.api.nvim_win_get_config(v.left_win).hide)
  assert(v.inline_cache and #vim.api.nvim_buf_get_extmarks(buf, v.inline_namespace, 0, -1, {}) > 0)
  assert(vim.bo[buf].modified and vim.bo[buf].buftype == "")
  for _, position in ipairs({ "left", "right", "top", "bottom" }) do
    plugin.set_explorer(v, { position = position })
  end
  plugin.toggle_explorer(v)
  assert(not v.explorer_win and v.alive)
  vim.cmd("DiffreelLayout side_by_side")
  ready(v)
  assert(vim.wo[win].diff and not vim.api.nvim_win_get_config(v.left_win).hide)
  assert(vim.api.nvim_win_get_position(v.left_win)[2] < vim.api.nvim_win_get_position(v.right_win)[2])
  assert(vim.bo[buf].modified and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "draft")
  vim.cmd("DiffreelLayout")
  assert(v.layout == "stacked")
  assert(vim.deep_equal(vim.fn.getcompletion("DiffreelLayout in", "cmdline"), { "inline" }))
  plugin.close(v)
  assert(vim.bo[buf].modified)
  for _, event in ipairs(events) do
    assert(event.name ~= "DiffreelReady" or event.current, "Ready preceded the current inline cache")
  end
end, debug.traceback)
plugin.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
