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

test("status markers use the configured symbols and preserve buffer-only priority", function()
  local expected = {
    added = "",
    modified = "",
    deleted = "",
    renamed = "",
    metadata = "~",
    limited = "!",
    typechange = "T",
    unchanged = "=",
    missing = "∅",
    buffer_only = "*",
    unknown = "?",
  }
  for status, marker in pairs(expected) do
    local entry = { path = "file.lua", status = status, buffer_only = status == "buffer_only" }
    if entry.buffer_only then
      entry.status = "modified"
    end
    local defaults = explorer.rows({ entry }, {}, 35)
    assert(defaults[1].text:sub(defaults[1].marker_col + 1) == marker, status)
    local custom = explorer.rows({ entry }, {}, 35, nil, nil, { status_icons = { [status] = "◆" } })
    assert(custom[1].text:sub(custom[1].marker_col + 1) == "◆", status)
  end
  local unknown = explorer.rows({ { path = "file", status = "future-status" } }, {}, 35)
  assert(unknown[1].text:sub(unknown[1].marker_col + 1) == "?")
end)

test("status marker width and byte spans survive clipping, statistics and resizing", function()
  local values = entries({ "src/deep/長いファイル名のテスト.lua" })
  local statistics = { [values[1].path] = { additions = 12, deletions = 3 } }
  for _, mode in ipairs({ "tree", "list" }) do
    for _, compact in ipairs({ false, true }) do
      for _, marker in ipairs({ "", "~", "変更", "[M]" }) do
        for _, stats in ipairs({ false, statistics }) do
          local tree = explorer.build(values)
          for _, width in ipairs({ 40, 26, 60 }) do
            local rows = explorer.rows(values, {}, width, tree, stats or nil, {
              mode = mode,
              compact = compact,
              status_icons = { modified = marker },
            })
            local row = rows[#rows]
            assert(vim.fn.strdisplaywidth(row.text) == width - 1, row.text)
            assert(row.text:sub(row.marker_col + 1) == marker)
            local span = row.highlights[#row.highlights]
            assert(span.group == "DiffreelExplorerModifiedMarker")
            assert(span.first == row.marker_col and span.last == #row.text)
            if stats then
              assert(row.text:find("+12 -3", 1, true))
            end
          end
        end
      end
    end
  end
end)

test("status icon changes invalidate a cached render even when the input table is reused", function()
  local values = entries({ "a/b/file" })
  local tree, folds = explorer.build(values), { ["a/b"] = true }
  local settings = { status_icons = { modified = "~" } }
  local folded = explorer.rows(values, folds, 35, tree, nil, settings)
  assert(#folded == 2)
  folds["a/b"] = nil
  local first = explorer.rows(values, folds, 35, tree, nil, settings)
  assert(explorer.rows(values, folds, 35, tree, nil, settings) == first)
  settings.status_icons.modified = "変更"
  local second = explorer.rows(values, folds, 35, tree, nil, settings)
  assert(second ~= first and second[#second].text:sub(second[#second].marker_col + 1) == "変更")
  assert(first[#first].text:sub(first[#first].marker_col + 1) == "~")
  assert(explorer.rows(values, folds, 35, tree, nil, settings) == second)
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
