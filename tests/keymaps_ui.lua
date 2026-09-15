vim.opt.rtp:prepend(vim.fn.getcwd())
vim.g.mapleader = ","
vim.cmd("filetype on")
local plugin = require("diffreel")
local failures, passed = {}, 0
local function input(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
end
local function wait(view, path)
  assert(
    vim.wait(5000, function()
      return view.error or (view.ready and not view.updating and (not path or view.selected_path == path))
    end, 5),
    "View did not become ready"
  )
  assert(not view.error, view.error)
end
local function mapping(buf, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end
local function test(name, body)
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
  local notify, timeout = vim.notify, vim.o.timeoutlen
  local ok, err = xpcall(function()
    git({ "init", "-q" })
    for _, file in ipairs({ "a.lua", "b.lua", "c.lua" }) do
      vim.fn.writefile({ "return 1" }, root .. "/" .. file)
    end
    git({ "add", "." })
    git({ "commit", "-qm", "Baseline" })
    for _, file in ipairs({ "a.lua", "b.lua", "c.lua" }) do
      vim.fn.writefile({ "return 2" }, root .. "/" .. file)
    end
    vim.api.nvim_cmd({ cmd = "edit", args = { root .. "/a.lua" } }, {})
    local normal, buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    plugin.setup({ watch = false, daemon = vim.env.DIFFREEL_DAEMON, keymaps = {} })
    local function open()
      local view = plugin.open({ root = root })
      wait(view)
      return view
    end
    body({ root = root, open = open, normal = normal, buffer = buffer })
  end, debug.traceback)
  vim.notify, vim.o.timeoutlen = notify, timeout
  plugin.shutdown()
  vim.cmd("silent! tabonly!")
  vim.cmd("silent! enew!")
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):sub(1, #root + 1) == root .. "/" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.fn.delete(root, "rf")
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end

test("overrides, counts, prefix chords and immediate typeahead", function(t)
  local seen, short, long = {}, 0, 0
  plugin.setup({
    keymaps = {
      explorer = {
        q = false,
        ["<Esc>"] = "close",
        ["]n"] = "next_file",
        g = function()
          short = short + 1
        end,
        gg = function()
          long = long + 1
        end,
        ["<Leader>x"] = function(ctx)
          seen[#seen + 1] = ctx
        end,
      },
    },
  })
  local view = t.open()
  assert(mapping(view.explorer_buf, "q").buffer ~= 1)
  assert(mapping(view.right_buf, "q").buffer == 1)
  input("2]n")
  wait(view, "c.lua")
  assert(vim.api.nvim_get_current_win() == view.explorer_win)
  input("<S-Tab>")
  wait(view, "b.lua")
  input("3,x")
  assert(#seen == 1 and seen[1].view == view and seen[1].count == 3)
  vim.o.timeoutlen = 50
  input("gg")
  assert(long == 1 and short == 0, "Short mapping consumed a longer chord")
  input(",e0iDRAFT <Esc>")
  assert(vim.api.nvim_get_current_win() == view.right_win)
  assert(vim.api.nvim_buf_get_lines(view.right_buf, 0, 1, false)[1] == "DRAFT return 2")
  input(",e<Esc>")
  assert(not view.alive)
end)

test("defaults can be disabled without unmapping user or native keys", function(t)
  local count = 0
  local original = function()
    count = count + 1
  end
  vim.keymap.set("n", "q", original, { buffer = t.buffer })
  plugin.setup({ keymaps = { defaults = false, explorer = { X = "close" } } })
  local view = t.open()
  for _, key in ipairs({ "<Tab>", "<S-Tab>", "<Leader>e", "R", "q" }) do
    assert(mapping(view.explorer_buf, key).buffer ~= 1)
  end
  assert(mapping(view.right_buf, "q").callback == original)
  assert(mapping(view.right_buf, "]c").buffer ~= 1)
  vim.api.nvim_set_current_win(view.right_win)
  input("q")
  assert(count == 1 and view.alive)
  vim.api.nvim_set_current_win(view.explorer_win)
  input("X")
  assert(not view.alive)
end)

test("active views lock changes but allow identical or unrelated setup", function(t)
  local fn = function() end
  local policy = { diff = { ["<Leader>x"] = fn } }
  plugin.setup({ keymaps = policy })
  local a, b = t.open(), t.open()
  assert(a.right_buf == b.right_buf)
  local config = plugin.config
  local maps = vim.api.nvim_buf_get_keymap(a.right_buf, "n")
  assert(not pcall(plugin.setup, { width = 99, keymaps = { defaults = false } }))
  assert(plugin.config == config and vim.deep_equal(maps, vim.api.nvim_buf_get_keymap(a.right_buf, "n")))
  plugin.setup({ keymaps = vim.deepcopy(policy) })
  vim.g.mapleader = ";"
  plugin.setup({ watch = false })
  assert(mapping(a.right_buf, ",x").buffer == 1)
  assert(not pcall(plugin.setup, { keymaps = policy }), "Explicit re-resolution changed a live leader")
  vim.g.mapleader = ","
  plugin.close(a)
  assert(not pcall(plugin.setup, { keymaps = {} }))
  plugin.close(b)
  plugin.setup({ keymaps = {} })
  local fresh = t.open()
  assert(mapping(fresh.right_buf, ",x").buffer ~= 1)
  assert(mapping(fresh.right_buf, "q").buffer == 1)
end)

test("invalid setup leaves opening usable and pending views lock reconfiguration", function(t)
  local config = plugin.config
  local buffers = #vim.api.nvim_list_bufs()
  assert(not pcall(plugin.setup, { keymaps = { diff = { [string.rep("x", 60)] = "close" } } }))
  assert(plugin.config == config and #vim.api.nvim_list_bufs() == buffers)
  local pending = plugin.open({ root = t.root })
  assert(not pending.ready)
  assert(not pcall(plugin.setup, { keymaps = { defaults = false } }))
  assert(plugin.config == config)
  plugin.close(pending)
  plugin.setup({ keymaps = { defaults = false, explorer = { X = "close" } } })
  local fresh = t.open()
  input("X")
  assert(not fresh.alive)
end)

test("shared buffers dispatch by current owner and restore after the last view", function(t)
  local seen, original_calls = {}, 0
  local original = function()
    original_calls = original_calls + 1
  end
  vim.keymap.set("n", "X", original, { buffer = t.buffer })
  plugin.setup({ keymaps = { diff = {
    X = function(ctx)
      seen[#seen + 1] = ctx
    end,
  } } })
  local a, b = t.open(), t.open()
  vim.api.nvim_set_current_win(t.normal)
  input("X")
  assert(original_calls == 1 and #seen == 0)
  vim.api.nvim_set_current_win(a.right_win)
  input("2X")
  vim.api.nvim_set_current_win(b.right_win)
  input("3X")
  assert(seen[1].view == a and seen[1].count == 2)
  assert(seen[2].view == b and seen[2].count == 3)
  plugin.close(a)
  assert(require("diffreel.lease").buffers[t.buffer])
  plugin.close(b)
  assert(not require("diffreel.lease").buffers[t.buffer])
  assert(mapping(t.buffer, "X").callback == original)
end)

test("reconfiguration waits for the final buffer lease to be released", function(t)
  local view = t.open()
  local presentation = require("diffreel.presentation")
  local dispose, changed = presentation.dispose, nil
  presentation.dispose = function(closing)
    changed = pcall(plugin.setup, { keymaps = { defaults = false } })
    dispose(closing)
  end
  local ok, err = pcall(plugin.close, view)
  presentation.dispose = dispose
  assert(ok, err)
  assert(changed == false, "Reentrant setup changed policy while a closing view still owned mappings")
  plugin.setup({ keymaps = { defaults = false } })
end)

test("a leased definition target does not borrow another view's actions", function(t)
  local called, fallback = 0, 0
  vim.keymap.set("n", "X", function()
    fallback = fallback + 1
  end, { buffer = t.buffer })
  plugin.setup({ keymaps = { diff = {
    X = function()
      called = called + 1
    end,
  } } })
  local a = t.open()
  plugin.select(a, "b.lua")
  wait(a, "b.lua")
  local b = t.open()
  assert(b.right_buf == t.buffer)
  vim.api.nvim_set_current_win(a.right_win)
  vim.api.nvim_win_set_buf(a.right_win, t.buffer)
  input("X")
  assert(called == 0 and fallback == 1, "Definition target ran another lease's callback")
  assert(vim.wait(1000, function()
    return a.navigation
  end))
  input("X")
  assert(called == 0 and fallback == 2)
  plugin.close(b)
  assert(mapping(t.buffer, "X").buffer == 1)
end)

test("later overrides and callback failures do not break cleanup", function(t)
  local errors = {}
  vim.notify = function(message, level)
    if level == vim.log.levels.ERROR then
      errors[#errors + 1] = message
    end
  end
  plugin.setup({ keymaps = { diff = {
    X = function()
      error("callback failure")
    end,
  } } })
  local view = t.open()
  vim.api.nvim_set_current_win(view.right_win)
  input("X")
  assert(#errors == 1 and errors[1]:find("callback failure", 1, true))
  local replacement = function() end
  vim.keymap.set("n", "X", replacement, { buffer = view.right_buf })
  local source = view.right_buf
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "draft" })
  input("q")
  assert(not view.alive and not require("diffreel.lease").buffers[source])
  assert(mapping(source, "X").callback == replacement)
  assert(vim.bo[source].modified and vim.api.nvim_buf_get_lines(source, 0, 1, false)[1] == "draft")
end)

for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
