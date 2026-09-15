vim.opt.rtp:prepend(vim.fn.getcwd())
local lease = require("diffreel.lease")
local failures, passed = {}, 0
local function test(name, body)
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  local ok, err = xpcall(function()
    body(buf)
  end, debug.traceback)
  for owner in pairs(lease.buffers[buf] and lease.buffers[buf].owners or {}) do
    pcall(lease.release, buf, owner)
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
local function input(keys)
  vim.api.nvim_feedkeys(keys, "xt", false)
end

test("dispatcher and action callback both require an owner", function(buf)
  local old, called = 0, 0
  vim.keymap.set("n", "X", function()
    old = old + 1
  end, { buffer = buf })
  local current = { id = "one" }
  lease.acquire(buf, "one", function()
    return current
  end, {
    X = function()
      called = called + 1
    end,
  })
  current = { id = "unrelated" }
  input("X")
  assert(called == 0 and old == 1, "Unrelated view intercepted the mapping")
  local run = vim.fn.maparg(lease.buffers[buf].maps.X.action_alias, "n", false, true).callback
  run()
  assert(called == 0, "Action alias accepted a stale owner")
  current = { id = "one" }
  input("X")
  assert(called == 1)
end)

test("internal aliases never replace existing mappings", function(buf)
  local fallback = ("<Plug>(DiffreelFallback-%d-1)"):format(buf)
  local action = ("<Plug>(DiffreelAction-%d-1)"):format(buf)
  local original = function() end
  vim.keymap.set("n", fallback, original, { buffer = buf })
  vim.keymap.set("n", action, original, { buffer = buf })
  lease.acquire(buf, "one", function()
    return nil
  end, { X = function() end })
  assert(vim.fn.maparg(fallback, "n", false, true).callback == original)
  assert(vim.fn.maparg(action, "n", false, true).callback == original)
  lease.release(buf, "one")
  assert(vim.fn.maparg(fallback, "n", false, true).callback == original)
  assert(vim.fn.maparg(action, "n", false, true).callback == original)
end)

test("native modifier aliases preserve original fallback and later overrides", function(buf)
  local old, tab, review = 0, 0, 0
  local original = function()
    old = old + 1
  end
  local replacement = function()
    tab = tab + 1
  end
  vim.keymap.set("n", "<C-i>", original, { buffer = buf })
  local raw = vim.fn.maparg("<C-i>", "n", false, true).lhsraw
  lease.acquire(buf, "one", function()
    return nil
  end, {
    ["<C-I>"] = function()
      review = review + 1
    end,
    ["<Tab>"] = function()
      review = review + 1
    end,
  })
  input(raw)
  input("\t")
  assert(old == 2 and review == 0, "Installing an alias changed the original fallback")
  vim.keymap.set("n", "<Tab>", replacement, { buffer = buf })
  lease.release(buf, "one")
  input("\t")
  assert(tab == 1, "Restoring an alternate key overwrote a later user mapping")
  input(raw)
  assert(old == 3, "Original modifier mapping was not restored")
end)

test("unmapped modifier falls back to the original alternate mapping", function(buf)
  vim.keymap.set("n", "<C-i>", function() end, { buffer = buf })
  local raw = vim.fn.maparg("<C-i>", "n", false, true).lhsraw
  vim.keymap.del("n", "<C-i>", { buffer = buf })
  local count = 0
  local original = function()
    count = count + 1
  end
  vim.keymap.set("n", "<Tab>", original, { buffer = buf })
  input(raw)
  assert(count == 1)
  lease.acquire(buf, "one", function()
    return nil
  end, { ["<C-I>"] = function() end }, { ["<C-I>"] = "\t" })
  input(raw)
  assert(count == 2, "Modifier fallback bypassed the original Tab mapping")
  lease.release(buf, "one")
  assert(vim.fn.maparg("<Tab>", "n", false, true).callback == original)
end)

for _, during in ipairs({ false, true }) do
  test("native pairing survives replacement " .. (during and "during" or "after") .. " a lease", function(buf)
    local old, new = 0, 0
    vim.keymap.set("n", "<C-i>", function()
      old = old + 1
    end, { buffer = buf })
    local replacement = function()
      new = new + 1
    end
    lease.acquire(buf, "one", function()
      return nil
    end, { ["<Tab>"] = function() end })
    if during then
      vim.keymap.set("n", "<C-i>", replacement, { buffer = buf })
    end
    lease.release(buf, "one")
    if not during then
      vim.keymap.set("n", "<C-i>", replacement, { buffer = buf })
    end
    input("\t")
    assert(new == 1 and old == 0, "Lease restoration split a native modifier from its alternate")
    local native = vim.api.nvim_buf_get_keymap(buf, "n")
    assert(#native == 1 and native[1].lhs == "<C-I>" and native[1].lhsrawalt == "\t")
  end)
end

for _, both in ipairs({ false, true }) do
  test("explicit alternate removal survives cleanup " .. tostring(both), function(buf)
    local original = function() end
    vim.keymap.set("n", "<C-i>", original, { buffer = buf })
    local actions = { ["<C-I>"] = function() end }
    if both then
      actions["<Tab>"] = function() end
    end
    lease.acquire(buf, "one", function()
      return nil
    end, actions, { ["<C-I>"] = "\t" })
    vim.keymap.del("n", "<Tab>", { buffer = buf })
    lease.release(buf, "one")
    local native = vim.api.nvim_buf_get_keymap(buf, "n")
    assert(#native == 1 and native[1].callback == original and native[1].lhs == "<C-I>")
    assert(not native[1].lhsrawalt, "Cleanup recreated an explicitly removed alternate")
  end)
end

test("literal notation and expression mappings survive reuse", function(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abc" })
  vim.keymap.set("n", "<lt>CR>", "$", { buffer = buf })
  vim.keymap.set("n", "X", function()
    return "i<Left>"
  end, { buffer = buf, expr = true, replace_keycodes = false })
  lease.acquire(buf, "one", function()
    return nil
  end, {
    ["<lt>CR>"] = function() end,
    X = function() end,
  })
  lease.acquire(buf, "two", function()
    return nil
  end, {})
  lease.release(buf, "one")
  assert(lease.buffers[buf])
  input("X" .. vim.keycode("<Esc>"))
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "<Left>abc")
  lease.release(buf, "two")
  local mapping = vim.fn.maparg("<lt>CR>", "n", false, true)
  assert(mapping.lhsraw == "<CR>" and mapping.rhs == "$")
  assert(vim.fn.maparg("X", "n", false, true).replace_keycodes == 0)
end)

test("ordinary windows observe global map additions replacements and removals", function(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcd" })
  local first, second = 0, 0
  lease.acquire(buf, "one", function()
    return nil
  end, { X = function() end })
  vim.keymap.set("n", "X", function()
    first = first + 1
  end)
  input("X")
  vim.keymap.set("n", "X", function()
    second = second + 1
  end)
  input("X")
  vim.keymap.del("n", "X")
  vim.api.nvim_win_set_cursor(0, { 1, 2 })
  input("X")
  assert(first == 1 and second == 1, "Fallback retained a stale global mapping")
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "acd")
end)

test("recursive mappings keep their literal self prefix and counts", function(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
  vim.keymap.set("n", "j", "jzz", { buffer = buf, remap = true })
  lease.acquire(buf, "one", function()
    return nil
  end, { j = function() end })
  vim.v.errmsg = ""
  input("2j")
  assert(vim.api.nvim_win_get_cursor(0)[1] == 3, vim.v.errmsg)
  assert(vim.v.errmsg == "")
end)

for _, expression in ipairs({
  "'jzz'",
  function()
    return "jzz"
  end,
}) do
  test("recursive expression mappings preserve prefix counts and typeahead " .. type(expression), function(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    vim.keymap.set("n", "j", expression, { buffer = buf, expr = true, remap = true })
    lease.acquire(buf, "one", function()
      return nil
    end, { j = function() end })
    vim.v.errmsg = ""
    input("2jl")
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 3, 1 }), vim.v.errmsg)
    assert(vim.v.errmsg == "")
  end)
end

test("recursive modifier mappings keep a distinct Tab RHS remappable", function(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcd" })
  vim.keymap.set("n", "<C-I>", "<Tab>", { buffer = buf, remap = true })
  local raw = vim.fn.maparg("<C-I>", "n", false, true).lhsraw
  vim.keymap.set("n", "<Tab>", "l", { buffer = buf })
  lease.acquire(buf, "one", function()
    return nil
  end, { ["<C-I>"] = function() end }, { ["<C-I>"] = "\t" })
  input(raw)
  assert(vim.api.nvim_win_get_cursor(0)[2] == 1)
end)

test("recursive modifier self mappings retain their native alternate prefix", function(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcd" })
  vim.keymap.set("n", "<C-I>", "<C-I>", { buffer = buf, remap = true })
  local raw = vim.fn.maparg("<C-I>", "n", false, true).lhsraw
  lease.acquire(buf, "one", function()
    return nil
  end, { ["<C-I>"] = function() end }, { ["<C-I>"] = "\t" })
  vim.v.errmsg = ""
  input(raw)
  assert(vim.v.errmsg == "", vim.v.errmsg)
end)

for _, both in ipairs({ false, true }) do
  test("later alternate mappings affect recursive fallback " .. tostring(both), function(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcd" })
    vim.keymap.set("n", "<C-I>", "<C-I>", { buffer = buf, remap = true })
    local raw = vim.fn.maparg("<C-I>", "n", false, true).lhsraw
    local actions = { ["<C-I>"] = function() end }
    if both then
      actions["<Tab>"] = function() end
    end
    lease.acquire(buf, "one", function()
      return nil
    end, actions, { ["<C-I>"] = "\t" })
    vim.v.errmsg = ""
    input(raw)
    assert(vim.v.errmsg == "", vim.v.errmsg)
    vim.keymap.set("n", "<Tab>", "l", { buffer = buf })
    input(raw)
    assert(vim.api.nvim_win_get_cursor(0)[2] == 1)
  end)
end

test("recursive expression callbacks may return nil without generating input", function(buf)
  local calls = 0
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcd" })
  vim.keymap.set("n", "X", function()
    calls = calls + 1
  end, { buffer = buf, expr = true, remap = true })
  lease.acquire(buf, "one", function()
    return nil
  end, { X = function() end })
  vim.v.errmsg = ""
  input("Xl")
  assert(calls == 1 and vim.v.errmsg == "", vim.v.errmsg)
  assert(vim.api.nvim_win_get_cursor(0)[2] == 1)
end)

test("script-only fallback mappings retain their native script context", function(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "abcd" })
  local dir = vim.fn.getcwd() .. "/.wadackel/qa/keymap-lease"
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/script-" .. vim.uv.hrtime() .. ".vim"
  vim.fn.writefile({ "nnoremap <buffer> <SID>Move l", "nmap <buffer> <script> Y <SID>Move" }, script)
  vim.cmd.source(vim.fn.fnameescape(script))
  vim.fn.delete(script)
  lease.acquire(buf, "one", function()
    return nil
  end, { Y = function() end })
  input("Y")
  assert(vim.api.nvim_win_get_cursor(0)[2] == 1)
end)

for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
