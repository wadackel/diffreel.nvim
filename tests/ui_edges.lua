vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = ","
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local function write(path, data)
  local file = assert(io.open(root .. "/" .. path, "wb"))
  file:write(data)
  file:close()
end
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
local plugin, first, second
local function wait(view, path)
  assert(vim.wait(5000, function()
    return view.error or (view.ready and not view.updating and view.selected_path == path)
  end, 5))
  assert(not view.error, view.error)
end
local ok, err = xpcall(function()
  git({ "init", "-q" })
  write("empty.txt", "old\n")
  write("bom.txt", "before\n")
  write("line\tbreak.txt", "before\n")
  write("gone.txt", "gone\n")
  write("source.txt", "moved\ncontent\nkept\n")
  write("large.txt", "small\n")
  git({ "add", "." })
  git({ "commit", "-qm", "baseline" })
  write("empty.txt", "")
  write("bom.txt", string.char(239, 187, 191) .. "after\r\n")
  write("line\tbreak.txt", "after\n")
  write("binary.bin", "a\0b")
  assert(vim.uv.fs_symlink("bom.txt", root .. "/link"))
  vim.fn.delete(root .. "/gone.txt")
  git({ "mv", "source.txt", "target.txt" })
  write("large.txt", string.rep("x", 2048) .. "\n")
  plugin = require("diffreel")
  plugin.setup({ backend = "rust", watch = false, max_bytes = 1024 })
  first = plugin.open({ root = root })
  assert(vim.wait(5000, function()
    return first.ready
  end, 5))
  for _, path in ipairs({ "empty.txt", "bom.txt", "line\tbreak.txt", "link", "binary.bin" }) do
    plugin.select(first, path)
    wait(first, path)
    assert(not first.disk_conflict, "Valid on-disk content was reported as a conflict: " .. path)
    if path == "bom.txt" then
      assert(vim.bo[first.right_buf].bomb and vim.bo[first.right_buf].fileformat == "dos")
      assert(vim.api.nvim_buf_get_lines(first.right_buf, 0, -1, false)[1] == "after")
    elseif path == "empty.txt" then
      assert(vim.api.nvim_buf_get_lines(first.right_buf, 0, -1, false)[1] == "")
      assert(first.by_path[path].right.exists)
    elseif path == "link" then
      assert(vim.bo[first.right_buf].buftype ~= "", "Symlink opened as a real buffer")
      assert(vim.api.nvim_buf_get_lines(first.right_buf, 0, -1, false)[1] == "bom.txt")
    elseif path == "binary.bin" then
      assert(vim.api.nvim_buf_get_lines(first.right_buf, 0, -1, false)[1] == "Not compared: binary")
    else
      assert(vim.api.nvim_buf_get_name(first.right_buf) == assert(vim.uv.fs_realpath(root)) .. "/" .. path)
    end
  end
  local function winbar(win)
    return vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true, maxwidth = 200 }).str
  end
  plugin.select(first, "gone.txt")
  wait(first, "gone.txt")
  assert(not winbar(first.right_win):find("newline", 1, true), "An absent side described its line ending")
  plugin.select(first, "target.txt")
  wait(first, "target.txt")
  assert(first.by_path["target.txt"].status == "renamed")
  assert(winbar(first.left_win):find("source.txt", 1, true), "The rename source was not identified")
  assert(winbar(first.right_win):find("target.txt", 1, true))
  plugin.select(first, "large.txt")
  wait(first, "large.txt")
  assert(vim.api.nvim_buf_get_lines(first.left_buf, 0, 1, false)[1] == "Not compared: too-large")
  assert(vim.api.nvim_buf_get_lines(first.right_buf, 0, 1, false)[1] == "Not compared: too-large")
  local unresolved = plugin.open({ root = root, left = "存在しないブランチ名" })
  assert(vim.wait(5000, function()
    return unresolved.error
  end, 5))
  local title = table.concat(vim.api.nvim_buf_get_lines(unresolved.explorer_buf, 0, -1, false), "\n")
  assert(title:find("存在しないブランチ名 → ", 1, true), title)
  plugin.close(unresolved)
  plugin.select(first, "bom.txt")
  wait(first, "bom.txt")
  local shared = first.right_buf
  second = plugin.open()
  assert(vim.wait(5000, function()
    return second.ready
  end, 5))
  plugin.select(second, "bom.txt")
  wait(second, "bom.txt")
  assert(second.right_buf == shared)
  plugin.close(first)
  assert(second.alive and vim.fn.maparg("q", "n", false, true).buffer == 1)
  vim.api.nvim_set_current_win(second.right_win)
  vim.api.nvim_feedkeys(",e", "xt", false)
  assert(vim.wait(1000, function()
    return vim.api.nvim_get_current_win() == second.explorer_win
  end, 5))
  vim.api.nvim_feedkeys(",e", "xt", false)
  assert(vim.api.nvim_get_current_win() == second.right_win)
  vim.api.nvim_feedkeys("q", "xt", false)
  assert(vim.wait(1000, function()
    return not second.alive
  end, 5))
  assert(vim.api.nvim_buf_is_valid(shared))
  vim.api.nvim_set_current_buf(shared)
  assert(not vim.wo.number, "Closing shared views retained review line numbers")
end, debug.traceback)
if first and first.alive then
  plugin.close(first)
end
if second and second.alive then
  plugin.close(second)
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
