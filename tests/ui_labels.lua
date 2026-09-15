vim.opt.rtp:prepend(vim.fn.getcwd())
local failures, passed = {}, 0
local function test(name, body)
  local ok, err = xpcall(body, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end

test("UI defaults merge without sharing tables or accepting invalid symbols", function()
  local ui, plugin = require("diffreel.ui"), require("diffreel")
  local input = { repository = "[repo]", commit = "%C" }
  plugin.setup({ ui_icons = input })
  plugin.setup({ ui_icons = { worktree = "[work]" } })
  assert(plugin.config.ui_icons.repository == "[repo]")
  assert(plugin.config.ui_icons.worktree == "[work]")
  assert(plugin.config.ui_icons.directory_open == "󰝰")
  input.repository = "mutated"
  assert(plugin.config.ui_icons.repository == "[repo]")
  assert(not pcall(require("diffreel.options").normalize, { ui_icons = {} }, plugin.config))
  local snapshot = ui.resolve(plugin.config.ui_icons)
  snapshot.repository = "snapshot"
  assert(plugin.config.ui_icons.repository == "[repo]")
  local before = vim.deepcopy(plugin.config)
  for _, value in ipairs({
    false,
    "x",
    { typo = "?" },
    { warning = "" },
    { warning = false },
    { warning = "a\nb" },
    { warning = "\0" },
    { warning = "\194\133" },
  }) do
    assert(not pcall(plugin.setup, { ui_icons = value }))
    assert(vim.deep_equal(before, plugin.config))
  end
end)

test("endpoint labels retain identity and escape winbar expressions", function()
  local ui = require("diffreel.ui")
  local icons = ui.resolve({ commit = "%{unsafe}", worktree = "W", index = "I", empty = "E" })
  assert(ui.endpoint(icons, "worktree") == "W Worktree")
  assert(ui.endpoint(icons, ":0") == "I Index")
  assert(ui.endpoint(icons, "") == "E Empty tree")
  assert(ui.endpoint(icons, "1234567890") == "%{unsafe} 12345678")
  assert(ui.endpoint(icons, "1234567890", "HEAD · 12345678") == "%{unsafe} HEAD · 12345678")
  assert(ui.winbar(ui.endpoint(icons, "1234567890")) == "%%{unsafe} 12345678")
end)

test("wrapped descriptions preserve every byte and keep wide characters intact", function()
  local ui = require("diffreel.ui")
  for _, text in ipairs({
    " Unsaved buffer differs from disk",
    "注意 日本語の長いパス/名前/ファイル.lua",
    "a\204\129 long description",
    string.rep("x", 180),
  }) do
    for _, width in ipairs({ 2, 3, 4, 12, 28, 60 }) do
      local parts = ui.wrap(text, width)
      local rebuilt = ""
      for i, part in ipairs(parts) do
        assert(vim.fn.strdisplaywidth(part.text) <= width, part.text)
        assert(part.prefix <= (i == 1 and 1 or 2))
        if width >= 4 then
          assert(part.prefix == (i == 1 and 1 or 2))
        end
        assert(part.first == #rebuilt)
        assert(part.text:sub(part.prefix + 1) == text:sub(part.first + 1, part.last))
        rebuilt = rebuilt .. part.text:sub(part.prefix + 1)
      end
      assert(rebuilt == text)
    end
  end
end)

test("footer anchors follow the same message and text after reflow", function()
  local ui = require("diffreel.ui")
  local text = " Unsaved buffer differs from disk"
  local function footer(width, start)
    local rows = {}
    for i, part in ipairs(ui.wrap(text, width)) do
      part.id = "conflict"
      rows[start + i] = part
    end
    return rows
  end
  local before = footer(40, 5)
  local offset = assert(text:find("differs", 1, true)) - 1
  local anchor = ui.anchor(before, 6, offset + 1)
  assert(anchor.id == "conflict" and anchor.offset == offset)
  local after = footer(18, 10)
  local row, col = ui.locate(after, anchor)
  assert(after[row].text:sub(col + 1, col + 7) == "differs")
  assert(ui.locate({}, anchor) == nil)
end)

test("folder symbols apply to collisions and invalidate cached rows", function()
  local ui, explorer = require("diffreel.ui"), require("diffreel.explorer")
  local entries = { { path = "src", status = "modified" }, { path = "src/deep/file", status = "added" } }
  local tree, folded = explorer.build(entries), {}
  local icons = ui.resolve()
  local rows = explorer.rows(entries, folded, 30, tree, nil, { compact = true }, icons)
  assert(rows[1].entry and rows[1].branch and rows[1].icon == "󰝰")
  assert(rows[2].text:find("󰝰", 1, true))
  folded.src = true
  local closed = explorer.rows(entries, folded, 30, tree, nil, {}, icons)
  assert(#closed == 1 and closed[1].icon == "󰉋")
  icons.directory_closed = "閉じる"
  local custom = explorer.rows(entries, folded, 30, tree, nil, {}, icons)
  assert(custom ~= closed and custom[1].icon == "閉じる")
  assert(vim.fn.strdisplaywidth(custom[1].text) == 29)
  assert(explorer.rows(entries, folded, 30, tree, nil, {}, icons) == custom)
  local flat = explorer.rows(entries, folded, 30, tree, nil, { mode = "list" }, icons)
  assert(#flat == 2 and not flat[1].branch and flat[1].icon ~= "閉じる")
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
