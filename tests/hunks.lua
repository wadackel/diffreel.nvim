vim.opt.rtp:prepend(vim.fn.getcwd())
local hunks = require("diffreel.hunks")
local passed, failures = 0, {}
local function test(name, left, right, body)
  vim.cmd("tabnew")
  local rw, rb = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(rb, 0, -1, false, right)
  local lb = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(lb, 0, -1, false, left)
  local lw = vim.api.nvim_open_win(lb, false, { split = "left", win = rw })
  local view = {
    alive = true,
    ready = true,
    left_win = lw,
    right_win = rw,
    left_buf = lb,
    right_buf = rb,
    empty_buf = -1,
    selected_path = "file",
    by_path = {
      file = {
        left = { kind = "text", exists = true, size = 10 },
        right = { kind = "text", exists = true, size = 10 },
      },
    },
  }
  for _, win in ipairs({ lw, rw }) do
    vim.api.nvim_win_call(win, function()
      vim.cmd.diffthis()
    end)
  end
  vim.api.nvim_set_current_win(rw)
  local ok, err = xpcall(function()
    body(view)
  end, debug.traceback)
  vim.cmd("tabclose!")
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
local original_diffopt = vim.o.diffopt
vim.o.diffopt = "internal,filler,linematch:40"
test(
  "native boundaries and count ranges preserve both views",
  { "old", "same", "old2", "same2", "old3" },
  { "new", "same", "new2", "same2", "new3" },
  function(v)
    vim.api.nvim_win_set_cursor(v.right_win, { 3, 1 })
    local positions = { vim.api.nvim_win_get_cursor(v.left_win), vim.api.nvim_win_get_cursor(v.right_win) }
    assert(hunks.boundary(v, v.right_win, false) == 1)
    assert(hunks.boundary(v, v.right_win, true) == 5)
    assert(
      vim.deep_equal(positions, { vim.api.nvim_win_get_cursor(v.left_win), vim.api.nvim_win_get_cursor(v.right_win) })
    )
    assert(vim.deep_equal(hunks.range(v, v.right_win, 2), { 3, 5 }))
    assert(hunks.move(v, v.right_win, 1) and vim.api.nvim_win_get_cursor(0)[1] == 5)
    assert(not hunks.move(v, v.right_win, 1))
  end
)
test("identical one-line files have no hunk", { "same" }, { "same" }, function(v)
  assert(not hunks.boundary(v, v.right_win, false))
  assert(not hunks.eligible(v, v.right_win))
end)
for _, filler in ipairs({ "internal", "internal,filler" }) do
  vim.o.diffopt = filler
  test(
    "deletion anchors without selectable text: " .. filler,
    { "deleted", "same", "tail", "deleted" },
    { "same", "tail" },
    function(v)
      assert(hunks.boundary(v, v.right_win, false) == 1)
      assert(hunks.boundary(v, v.right_win, true) == 2)
      assert(not hunks.range(v, v.right_win, 1))
    end
  )
end
vim.o.diffopt = "internal,filler,linematch:40"
test(
  "native linematch boundaries split touching highlights",
  { "a", "a", "a", "a" },
  { "a", "b", "b", "b", "b" },
  function(v)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local range = hunks.range(v, v.right_win, 1)
    assert(range and range[1] == 2)
  end
)
test("missing placeholder is not text", { "old" }, { "" }, function(v)
  v.empty_buf = v.right_buf
  v.by_path.file.right = { kind = "missing", exists = false }
  assert(not hunks.eligible(v, v.right_win))
end)
test("unsaved native diff and whitespace settings", { "same", "word" }, { "same", "word" }, function(v)
  vim.api.nvim_buf_set_lines(v.right_buf, 1, 2, false, { "WORD" })
  assert(hunks.boundary(v, v.right_win, false) == 2)
  vim.o.diffopt = "internal,icase"
  assert(not hunks.boundary(v, v.right_win, false))
end)
vim.o.diffopt = original_diffopt
for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
