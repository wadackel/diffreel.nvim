vim.opt.rtp:prepend(vim.fn.getcwd())
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
  local result = vim.system(command, { cwd = root }):wait()
  assert(result.code == 0, result.stderr)
end
local function highlight(win, name)
  for from, to in vim.wo[win].winhighlight:gmatch("([^,:]+):([^,]+)") do
    if from == name then
      return vim.api.nvim_get_hl(0, { name = to, link = false })
    end
  end
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end
local plugin, view
local ok, err = xpcall(function()
  local presentation = require("diffreel.presentation")
  local window, global_fills = vim.api.nvim_get_current_win(), vim.go.fillchars
  for _, diff in ipairs({ "╱", "-", " ", "" }) do
    for _, scope in ipairs({ "global", "local" }) do
      local value = "vert:|,eob:~" .. (diff == "" and "" or ",diff:" .. diff)
      vim.go.fillchars = scope == "global" and value or "diff:╱"
      local original = scope == "local" and value or ""
      vim.api.nvim_set_option_value("fillchars", original, { win = window, scope = "local" })
      local expected = vim.opt_local.fillchars:get().diff
      local styled = {}
      presentation.chrome(styled, window, "Diff")
      assert(vim.opt_local.fillchars:get().diff == expected, "Review replaced the " .. scope .. " diff filler")
      assert(vim.opt_local.fillchars:get().eob == " ", "Review end-of-buffer rows are not blank")
      presentation.restore(styled, window)
      assert(
        vim.api.nvim_get_option_value("fillchars", { win = window, scope = "local" }) == original,
        "Restoring diff fill characters lost the original local value"
      )
    end
  end
  vim.go.fillchars = "vert:|"
  vim.api.nvim_set_option_value("fillchars", "", { win = window, scope = "local" })
  local snapshot = presentation.capture_window(window)
  local styled = {}
  presentation.chrome(styled, window, "Explorer")
  presentation.restore(styled, window)
  assert(
    vim.api.nvim_get_option_value("fillchars", { win = window, scope = "local" }) == "",
    "Restoring fill characters lost global inheritance"
  )
  vim.go.fillchars = "vert:!"
  assert(vim.api.nvim_get_option_value("fillchars", { win = window }) == "vert:!")
  presentation.restore_window(window, snapshot)
  assert(vim.api.nvim_get_option_value("fillchars", { win = window }) == "vert:!")
  for _, scope in ipairs({ "Explorer", "Diff" }) do
    presentation.chrome(styled, window, scope)
    vim.wo[window].fillchars = "eob:#,diff:-"
    presentation.chrome(styled, window, scope)
    presentation.restore(styled, window)
    assert(vim.wo[window].fillchars == "eob:#,diff:-", "Cleanup replaced a later fillchars edit")
  end
  vim.api.nvim_set_option_value("fillchars", "", { win = window, scope = "local" })
  vim.go.fillchars = global_fills
  git({ "init", "-q" })
  vim.fn.writefile({ "removed" }, root .. "/a.txt")
  vim.fn.writefile({ "same", "before" }, root .. "/main.txt")
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  vim.fn.delete(root .. "/a.txt")
  vim.fn.writefile({ "same", "after" }, root .. "/main.txt")
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x123040 })
  vim.api.nvim_set_hl(0, "DiffDelete", { fg = 0x503040, reverse = true })
  local global = vim.api.nvim_get_hl(0, { name = "DiffChange" })
  vim.cmd.edit(root .. "/main.txt")
  local normal, real = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.wo[normal].winhighlight = "Normal:Normal"
  vim.wo[normal].number = false
  vim.opt_local.fillchars = { eob = "~", diff = "╱", fold = "·", vert = "," }
  local original_fillchars = vim.wo[normal].fillchars
  local other = vim.api.nvim_create_buf(true, false)
  local target_window = vim.api.nvim_open_win(other, true, { split = "right", win = normal })
  vim.wo[target_window].number = true
  vim.wo[target_window].winhighlight = "Normal:Normal"
  vim.api.nvim_set_current_win(normal)
  plugin = require("diffreel")
  plugin.setup({ backend = "rust", watch = false })
  view = plugin.open({ root = root })
  assert(vim.wait(5000, function()
    return view.ready
  end, 5))
  plugin.select(view, "main.txt")
  assert(vim.wait(5000, function()
    return view.ready and view.selected_path == "main.txt"
  end, 5))
  assert(vim.wo[view.right_win].number, "A reused buffer lost its review line numbers")
  local defaults = require("diffreel.highlights").defaults()
  assert(highlight(view.left_win, "DiffChange").bg == defaults.DiffreelLineDelete.bg)
  assert(highlight(view.right_win, "DiffChange").bg == defaults.DiffreelLineAdd.bg)
  local fills = vim.api.nvim_win_call(view.right_win, function()
    return vim.opt_local.fillchars:get()
  end)
  assert(fills.eob == " " and fills.diff == "╱", "Review replaced the configured diff filler")
  assert(
    fills.fold == "·" and vim.wo[view.right_win].fillchars:find("vert:,", 1, true),
    "Review changed unrelated fill characters"
  )
  assert(vim.wo[normal].fillchars == original_fillchars, "Review fill characters leaked into an ordinary window")
  assert(highlight(view.right_win, "DiffText").bg ~= highlight(view.right_win, "DiffChange").bg)
  assert(highlight(view.left_win, "DiffText").bg ~= highlight(view.left_win, "DiffChange").bg)
  assert(highlight(view.right_win, "DiffTextAdd").bg == highlight(view.right_win, "DiffText").bg)
  assert(not highlight(view.left_win, "DiffDelete").reverse)
  local remapping = vim.wo[view.right_win].winhighlight
  local review_fillchars = vim.wo[view.right_win].fillchars
  require("diffreel.presentation").apply(view, view.right_win)
  require("diffreel.presentation").apply(view, view.right_win)
  assert(vim.wo[view.right_win].winhighlight == remapping, "Repeated styling changed highlight aliases")
  assert(vim.wo[view.right_win].fillchars == review_fillchars, "Repeated styling accumulated fill characters")
  assert(remapping:find("Normal:Normal", 1, true), "Review chrome replaced an existing Normal alias")
  assert(vim.wo[view.left_win].foldcolumn == "1" and vim.wo[view.right_win].foldcolumn == "1")
  assert(vim.wo[view.explorer_win].winbar:find("2 files", 1, true))
  assert(vim.wo[view.explorer_win].winbar:find("2 / 2 files", 1, true), "File position is missing")
  assert(vim.wo[view.right_win].winbar:find("Working tree", 1, true))
  assert(vim.wo[normal].winhighlight == "Normal:Normal")
  assert(vim.deep_equal(global, vim.api.nvim_get_hl(0, { name = "DiffChange" })))
  vim.api.nvim_win_set_buf(view.right_win, other)
  local recalled_number = vim.wo[view.right_win].number
  assert(vim.wait(1000, function()
    return view.navigation
  end, 5))
  assert(vim.wo[view.right_win].winhighlight == "Normal:Normal", "Review colors leaked into navigation")
  assert(vim.wo[view.right_win].number == recalled_number, "Source options replaced the destination's settings")
  vim.api.nvim_win_set_buf(view.right_win, real)
  assert(vim.wait(1000, function()
    return view.ready and not view.navigation
  end, 5))
  assert(highlight(view.right_win, "DiffChange").bg == defaults.DiffreelLineAdd.bg)
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = 0x203050 })
  vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
  assert(
    highlight(view.right_win, "DiffChange").bg == require("diffreel.highlights").defaults().DiffreelLineAdd.bg,
    "Colors did not follow the theme"
  )
  vim.api.nvim_set_current_tabpage(view.return_tab)
  vim.cmd("tabclose")
  vim.api.nvim_set_current_win(view.right_win)
  vim.api.nvim_buf_set_lines(real, 0, -1, false, { "unsaved source" })
  vim.api.nvim_win_set_buf(view.right_win, other)
  assert(vim.wait(1000, function()
    return view.navigation
  end, 5))
  plugin.close(view)
  vim.api.nvim_set_current_buf(real)
  assert(not vim.wo.diff, "Closing the last review tab retained hidden diff membership")
  assert(not vim.wo.winhighlight:find("Diffreel", 1, true), "Closed review styling returned with its hidden buffer")
  assert(not vim.wo.number, "Closed review line numbers returned with its hidden buffer")
  assert(
    vim.wo.fillchars == "" or vim.wo.fillchars == original_fillchars,
    "Closed review fill characters returned with its hidden buffer"
  )
  assert(vim.bo[real].modified and vim.api.nvim_buf_get_lines(real, 0, 1, false)[1] == "unsaved source")
end, debug.traceback)
if view then
  plugin.close(view)
end
if plugin then
  plugin.shutdown()
end
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
