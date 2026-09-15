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
  local result = vim.system(command, { cwd = root, text = true }):wait()
  assert(result.code == 0, result.stderr)
end
git({ "init", "-q" })
vim.fn.writefile({ "base" }, root .. "/a")
git({ "add", "." })
git({ "commit", "-qm", "base" })
vim.fn.writefile({ "changed" }, root .. "/a")
local diffreel = require("diffreel")
local ok, err = xpcall(function()
  diffreel.setup({
    watch = false,
    keymaps = {
      explorer = { q = false, H = "show_help", X = function() end },
      diff = { ["g?"] = false, H = "show_help", Y = function() end },
    },
  })
  local view = diffreel.open({ root = root })
  assert(
    vim.wait(10000, function()
      return view.ready or view.error
    end, 5),
    "View timed out"
  )
  assert(not view.error, view.error)
  local open_win = vim.api.nvim_open_win
  vim.api.nvim_open_win = function()
    error("fixture help window failure")
  end
  local opened, failure = pcall(diffreel.show_help, view)
  vim.api.nvim_open_win = open_win
  assert(not opened and tostring(failure):find("fixture help window failure", 1, true))
  assert(not view.help and view.alive)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    assert(
      vim.api.nvim_buf_get_name(buf) ~= "diffreel://" .. view.id .. "/help",
      "Failed help creation leaked its buffer"
    )
  end
  local function rows()
    return vim.api.nvim_buf_get_lines(view.help.buf, 0, -1, false)
  end
  local function action(key)
    for _, line in ipairs(rows()) do
      local lhs, value = line:match("^%s*(%S+)%s+(.+)$")
      if lhs == key then
        return value
      end
    end
  end
  local function press(key)
    vim.api.nvim_feedkeys(vim.keycode(key), "xt", false)
  end
  vim.keymap.set("n", "R", function() end, { buffer = view.explorer_buf })
  press("H")
  assert(view.help and vim.api.nvim_win_is_valid(view.help.win))
  assert(action("H") == "Show help" and action("g?") == "Show help")
  assert(action("X") == "Custom action" and not action("q") and not action("R"))
  local help_buf = view.help.buf
  press("q")
  assert(view.alive and not view.help and not vim.api.nvim_buf_is_valid(help_buf))
  assert(vim.api.nvim_get_current_win() == view.explorer_win)
  vim.api.nvim_set_current_win(view.right_win)
  local draft = view.right_buf
  vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "unsaved" })
  vim.keymap.set("n", "]f", function() end, { buffer = draft })
  press("H")
  assert(action("H") == "Show help" and action("Y") == "Custom action")
  assert(not action("g?") and not action("]f"))
  assert(not action("X"), "Explorer callbacks leaked into diff help")
  help_buf = view.help.buf
  diffreel.close(view)
  assert(not view.alive and not vim.api.nvim_buf_is_valid(help_buf))
  assert(vim.bo[draft].modified and vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "unsaved")
end, debug.traceback)
diffreel.shutdown()
vim.fn.delete(root, "rf")
if not ok then
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = ok }))
vim.cmd(ok and "qa!" or "cquit 1")
