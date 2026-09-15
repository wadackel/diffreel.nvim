local probe = assert(loadfile("benchmarks/probe.lua"))(0)
local left, right = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(left, 0, -1, false, { "old", "second" })
vim.api.nvim_buf_set_lines(right, 0, -1, false, { "new", "wrong" })
local left_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(left_win, left)
local right_win = vim.api.nvim_open_win(right, true, { split = "right", win = left_win })
for _, win in ipairs({ left_win, right_win }) do
  vim.wo[win].diff = true
end
_G.diffreel_expected_path = "a"
_G.diffreel_expected_line = "new"
_G.diffreel_expected_hashes = { a = vim.fn.sha256("new\nsecond\n") }
_G.diffreel_expected_left_hashes = { a = vim.fn.sha256("old\nsecond\n") }
local view = {
  selected_path = "a",
  left_buf = left,
  right_buf = right,
  left_win = left_win,
  right_win = right_win,
  by_path = { a = { right = { content_id = diffreel_expected_hashes.a } } },
}
assert(probe.matches, "Full-content readiness verifier is missing")
assert(not probe.matches(view), "Wrong lower line was accepted")
vim.api.nvim_buf_set_lines(right, 0, -1, false, { "new", "second" })
vim.api.nvim_buf_set_lines(left, 0, -1, false, { "wrong", "second" })
assert(not probe.matches(view), "Wrong baseline was accepted")
vim.api.nvim_buf_set_lines(left, 0, -1, false, { "old", "second" })
vim.wo[left_win].diff = false
assert(not probe.matches(view), "Missing diff mode was accepted")
vim.wo[left_win].diff = true
assert(probe.matches(view))
_G.diffreel_expected_buffer_hash = vim.fn.sha256("draft\nsecond\n")
vim.api.nvim_buf_set_lines(right, 0, -1, false, { "draft", "second" })
assert(probe.matches(view), "An expected draft was compared against the disk hash")
view.by_path.a.right.content_id = "wrong"
assert(not probe.matches(view), "Draft validation skipped snapshot metadata")
view.by_path.a.right.content_id = diffreel_expected_hashes.a
vim.api.nvim_buf_set_lines(right, 0, -1, false, { "draft", "wrong" })
assert(not probe.matches(view), "Draft validation accepted a wrong lower line")
_G.diffreel_expected_buffer_hash = nil
vim.api.nvim_buf_set_lines(right, 0, -1, false, { "new", "second" })
_G.diffreel_expected_unchanged_line = 2
local ghost = vim.api.nvim_create_buf(false, true)
local extra = vim.api.nvim_open_win(ghost, true, { split = "below", win = right_win })
vim.wo[extra].diff = true
vim.api.nvim_win_close(extra, true)
vim.cmd("diffupdate")
assert(not probe.matches(view), "A hidden third diff participant was accepted")
print("full-buffer readiness verification passed")
vim.cmd("qa!")
