vim.opt.rtp:prepend(vim.fn.getcwd())
local explorer = require("diffreel.explorer")
local failures, passed = {}, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
local function entries(paths)
  local result = {}
  for _, path in ipairs(paths) do
    result[#result + 1] = { path = path, status = "modified" }
  end
  return result
end

test("compact rows keep underlying paths and visible parent navigation", function()
  local values = entries({ "a/b/c/one.lua", "a/b/c/two.lua", "a/other.lua" })
  local tree = explorer.build(values)
  local folds = {}
  local rows = explorer.rows(values, folds, 40, tree, nil, { compact = true })
  assert(#rows == 5)
  assert(rows[2].path == "a/b/c" and rows[2].text:find("b/c", 1, true))
  assert(rows[2].name == "c" and rows[2].parent_path == "a")
  assert(explorer.cursor_path(rows, "a/b") == "a/b/c")
  assert(explorer.act(tree, folds, rows[2].path, "parent", rows[2]) == "a")
  assert(explorer.act(tree, folds, rows[2].path, "collapse_node", rows[2]) == "a/b/c")
  local collapsed = explorer.rows(values, folds, 40, tree, nil, { compact = true })
  assert(#collapsed == 3 and collapsed[2].path == "a/b/c")
  assert(explorer.act(tree, folds, collapsed[2].path, "collapse_node", collapsed[2]) == "a")
  assert(folds.a)
end)

test("compaction preserves existing fold boundaries and file-directory overlaps", function()
  local values = entries({ "root/chain/leaf/a", "root/chain/leaf/b", "mixed", "mixed/child" })
  local tree = explorer.build(values)
  local folds = { ["root/chain"] = true }
  local rows = explorer.rows(values, folds, 45, tree, nil, { compact = true })
  assert(rows[1].path == "root/chain" and rows[1].directory)
  assert(rows[2].path == "mixed" and rows[2].entry and rows[2].branch)
  assert(rows[3].path == "mixed/child")
  explorer.act(tree, folds, "root/chain", "expand_recursive", rows[1])
  rows = explorer.rows(values, folds, 45, tree, nil, { compact = true })
  assert(rows[1].path == "root/chain/leaf")
end)

test("flat listing uses full paths and consistent sorted navigation", function()
  local values = entries({ "z/b", "a.txt", "z", "b/x/y" })
  local tree = explorer.build(values)
  local order = explorer.ordered(tree, "list")
  assert(order[1].path == "a.txt" and order[2].path == "b/x/y" and order[3].path == "z" and order[4].path == "z/b")
  local folds = { z = true }
  local rows = explorer.rows(values, folds, 45, tree, nil, { mode = "list", compact = true })
  assert(#rows == 4 and rows[2].text:find("b/x/y", 1, true))
  for _, row in ipairs(rows) do
    assert(row.entry and not row.directory and not row.branch)
  end
  assert(rows[2].name == "y")
  assert(explorer.cursor_path(rows, "b/x") == "b/x/y")
  assert(explorer.act(tree, folds, "z", "collapse_node", rows[3]) == nil and folds.z == true)
  assert(explorer.ordered(tree, "tree") == tree.entries)
end)

test("render cache tracks listing and compact settings alongside statistics", function()
  local values = entries({ "a/b/file" })
  local tree, folds = explorer.build(values), {}
  local original = explorer.rows(values, folds, 35, tree)
  assert(#original == 3)
  local compact = explorer.rows(values, folds, 35, tree, nil, { compact = true })
  assert(#compact == 2 and compact ~= original)
  assert(explorer.rows(values, folds, 35, tree, nil, { compact = true }) == compact)
  local flat = explorer.rows(values, folds, 35, tree, nil, { mode = "list" })
  assert(#flat == 1 and flat ~= compact)
  local counted = explorer.rows(
    values,
    folds,
    35,
    tree,
    { ["a/b/file"] = { additions = 1, deletions = 2 } },
    { mode = "list" }
  )
  assert(counted[1].text:find("+1 -2", 1, true))
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
