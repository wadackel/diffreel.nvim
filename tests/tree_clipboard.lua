vim.opt.rtp:prepend(vim.fn.getcwd())
local explorer, keymaps = require("diffreel.explorer"), require("diffreel.keymaps")
local copied, provider_error, errors = {}, false, {}
vim.g.clipboard = {
  name = "diffreel-tree-fixture",
  copy = {
    ["+"] = function(lines, kind)
      if provider_error then
        error("Clipboard fixture failure")
      end
      copied[#copied + 1] = { text = table.concat(lines, "\n"), kind = kind }
    end,
    ["*"] = function()
      error("Unexpected clipboard register")
    end,
  },
  paste = {
    ["+"] = function()
      return { { "" }, "v" }
    end,
    ["*"] = function()
      return { { "" }, "v" }
    end,
  },
}
vim.notify = function(message, level)
  if level == vim.log.levels.ERROR then
    errors[#errors + 1] = message
  end
end
local weird = "name [1]\\part\tline\n日本.lua"
local input = {
  { path = "src/" .. weird, status = "modified" },
  { path = "gone.txt", status = "deleted" },
  { path = "new.txt", old_path = "old.txt", status = "renamed" },
  { path = "binary.bin", status = "limited" },
  { path = "draft.txt", status = "modified", buffer_only = true },
}
local rows, tree = explorer.rows(input, {}, 12)
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(
  buf,
  0,
  -1,
  false,
  { "header", "baseline", "", unpack(vim.tbl_map(function(r)
    return r.text
  end, rows)) }
)
local view = { root = "/missing/worktree", explorer_win = vim.api.nvim_get_current_win(), rows = rows, tree = tree }
local policy =
  keymaps.resolve({ defaults = false, explorer = { a = "yank_path", b = "yank_path_absolute", c = "yank_name" } })
local bindings = keymaps.bindings(policy.explorer, {}, function()
  error("Copy must not render or select")
end)
for i, row in ipairs(rows) do
  vim.api.nvim_win_set_cursor(view.explorer_win, { i + 3, 0 })
  bindings.a(view, 3)
  assert(copied[#copied].text == row.path and copied[#copied].kind == "v")
  bindings.b(view, 1)
  assert(copied[#copied].text == view.root .. "/" .. row.path)
  bindings.c(view, 1)
  assert(copied[#copied].text == row.name)
end
local count = #copied
vim.api.nvim_win_set_cursor(view.explorer_win, { 1, 0 })
bindings.a(view, 1)
assert(#copied == count and #errors == 0)
vim.api.nvim_win_set_cursor(view.explorer_win, { 4, 0 })
local has = vim.fn.has
vim.fn.has = function(feature)
  return feature == "clipboard" and 0 or has(feature)
end
bindings.a(view, 1)
vim.fn.has = has
assert(#copied == count and #errors == 1 and errors[1]:lower():find("clipboard", 1, true))
provider_error = true
bindings.a(view, 1)
assert(#copied == count and #errors == 2 and errors[2]:find("Clipboard fixture failure", 1, true))
vim.api.nvim_buf_delete(buf, { force = true })
print(vim.json.encode({ passed = true, rows = #rows, checks = 3 * #rows + 3 }))
