vim.opt.rtp:prepend(vim.fn.getcwd())
local explorer = require("diffreel.explorer")
local failures, passed = {}, 0
local function test(name, body)
  local ok, err = xpcall(body, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end
local function entries(paths)
  return vim.tbl_map(function(path)
    return { path = path, status = "modified" }
  end, paths)
end
local paths = { "root.lua", "src/a.lua", "src/deep/b.lua", "src/deep/more/c.lua", "src-other/d.lua" }
local function visible(rows)
  local result = {}
  for _, row in ipairs(rows) do
    result[row.path] = row
  end
  return result
end

test("single collapse preserves descendants while recursive collapse resets them", function()
  local tree, folded = explorer.build(entries(paths)), {}
  assert(explorer.act(tree, folded, "src", "collapse_node") == "src")
  assert(folded.src and not folded["src/deep"])
  explorer.act(tree, folded, "src", "toggle")
  assert(not folded.src and not folded["src/deep"])
  assert(explorer.act(tree, folded, "src/deep/b.lua", "collapse_recursive") == "src/deep")
  assert(folded["src/deep"] and folded["src/deep/more"] and not folded["src-other"])
  explorer.act(tree, folded, "src/deep", "toggle")
  assert(not folded["src/deep"] and folded["src/deep/more"])
  assert(explorer.act(tree, folded, "src/deep/b.lua", "expand_recursive") == "src/deep/b.lua")
  assert(not folded["src/deep"] and not folded["src/deep/more"])
end)

test("parent and collapse-node stop at the implicit root", function()
  local tree, folded = explorer.build(entries(paths)), {}
  assert(explorer.act(tree, folded, "src/deep/b.lua", "parent") == "src/deep")
  assert(not next(folded))
  assert(explorer.act(tree, folded, "src/deep/b.lua", "collapse_node") == "src/deep")
  assert(folded["src/deep"])
  assert(explorer.act(tree, folded, "src/deep", "collapse_node") == "src")
  assert(folded.src)
  assert(explorer.act(tree, folded, "src", "collapse_node") == nil)
  assert(explorer.act(tree, folded, "root.lua", "parent") == nil)
  assert(explorer.act(tree, folded, "root.lua", "collapse_recursive") == "root.lua")
  assert(folded["src-other"] and folded["src/deep/more"] and not folded[""])
  explorer.act(tree, folded, "root.lua", "expand_recursive")
  assert(not next(folded))
end)

test("global operations include hidden descendants and resolve visible ancestors", function()
  local input, folded = entries(paths), {}
  local tree = explorer.build(input)
  explorer.act(tree, folded, "src/deep/more/c.lua", "collapse_all")
  assert(folded.src and folded["src/deep"] and folded["src/deep/more"] and folded["src-other"])
  local rows = explorer.rows(input, folded, 30)
  assert(explorer.cursor_path(rows, "src/deep/more/c.lua") == "src")
  assert(explorer.cursor_path(rows, "src-other/d.lua") == "src-other")
  assert(not visible(rows)["src/deep"])
  explorer.act(tree, folded, nil, "expand_all")
  assert(not next(folded) and visible(explorer.rows(input, folded, 30))["src/deep/more/c.lua"])
  assert(explorer.act(tree, folded, nil, "parent") == nil)
  assert(explorer.act(explorer.build({}), {}, nil, "collapse_all") == nil)
  assert(explorer.cursor_path({}, "missing") == nil)
end)

test("comparison entries with children remain selectable and collapsible", function()
  local input, folded = entries({ "src", "src/a.lua", "src/nested/b.lua" }), {}
  local tree = explorer.build(input)
  local row = visible(explorer.rows(input, folded, 30)).src
  assert(row.entry and row.branch and not row.directory)
  assert(row.text:find("▾", 1, true))
  local child = visible(explorer.rows(input, folded, 30))["src/a.lua"]
  assert(
    vim.fn.strdisplaywidth(child.text:sub(1, child.name_col))
      == vim.fn.strdisplaywidth(row.text:sub(1, row.name_col)) + 2,
    "child names must be indented beneath a selectable branch"
  )
  explorer.act(tree, folded, "src", "collapse_node")
  local rows = explorer.rows(input, folded, 30)
  assert(#rows == 1 and rows[1].entry == input[1] and rows[1].text:find("▸", 1, true))
  explorer.act(tree, folded, "src", "expand_recursive")
  assert(visible(explorer.rows(input, folded, 30))["src/nested/b.lua"])
end)

test("render reconciles folds against all current entries and preserves raw names", function()
  local name = "name [1]\\part\tline\n日本.lua"
  local retained = { path = "draft/file.lua", status = "modified", buffer_only = true }
  local input = entries({ "src/" .. name, "src-other/d.lua", "new/deep/file.lua" })
  input[#input + 1] = retained
  local folded = { src = true, removed = true, ["removed/deep"] = true, draft = true }
  local rows, tree = explorer.rows(input, folded, 30)
  assert(folded.src and folded.draft and not folded.removed and not folded["removed/deep"])
  assert(visible(rows)["new/deep/file.lua"] and tree.nodes[retained.path].entry == retained)
  assert(tree.nodes["src/" .. name].name == name)
  explorer.reveal(folded, "src/" .. name)
  local row = visible(explorer.rows(input, folded, 20))["src/" .. name]
  assert(row.name == name and row.path == "src/" .. name and not row.text:find("\n", 1, true))
  assert(folded.draft)
  local replacement = { path = retained.path, status = "deleted", buffer_only = true }
  input[#input] = replacement
  local _, fresh = explorer.rows(input, folded, 30)
  assert(fresh.nodes[retained.path].entry == replacement)
end)

test("directory labels fit the explorer width without changing raw paths", function()
  local name = string.rep("directory", 10)
  local rows = explorer.rows(entries({ name .. "/file.lua" }), {}, 24)
  assert(vim.fn.strdisplaywidth(rows[1].text) <= 24, "Directory label was not clipped")
  assert(rows[1].text:find("…", 1, true) and rows[1].name == name)
end)

test("escaped display names remain distinguishable and hide control bytes", function()
  assert(explorer.display("line\nname") ~= explorer.display("line\\nname"))
  local raw = "escape" .. string.char(27) .. "[31m" .. string.char(1, 127)
  assert(not explorer.display(raw):find("[%z\1-\31\127]"))
  local row = explorer.rows(entries({ raw }), {}, 100)[1]
  assert(row.path == raw and row.name == raw)
end)

test("reused hierarchy follows fold width and replacement metadata changes", function()
  local input, folded = entries({ "src/long-file-name.lua", "src/deep/child.lua" }), {}
  local tree = explorer.build(input)
  assert(visible(explorer.rows(input, folded, 40, tree))["src/deep/child.lua"])
  explorer.act(tree, folded, "src", "collapse_node")
  assert(#explorer.rows(input, folded, 40, tree) == 1)
  explorer.act(tree, folded, "src", "expand_recursive")
  local narrow = visible(explorer.rows(input, folded, 12, tree))["src/long-file-name.lua"]
  assert(narrow.text:find("…", 1, true) and narrow.path == input[1].path)
  input[1] = { path = input[1].path, status = "deleted" }
  local fresh = explorer.build(input)
  local row = visible(explorer.rows(input, folded, 40, fresh))[input[1].path]
  assert(row.entry == input[1] and row.text:sub(row.marker_col + 1) == "")
end)

for _, failure in ipairs(failures) do
  io.stderr:write(failure .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
