local run = assert(vim.env.DIFFREEL_DEMO_RUN)
local scene = assert(vim.env.DIFFREEL_DEMO_SCENE)
local root = assert(vim.env.DIFFREEL_DEMO_ROOT)
local repo = run .. "/diffreel-demo"

vim.opt.rtp:prepend(vim.env.DIFFREEL_DEMO_THEME)
vim.opt.rtp:prepend(vim.env.DIFFREEL_DEMO_ICONS)
vim.opt.rtp:prepend(root)
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.swapfile = false
vim.o.undofile = false
vim.o.exrc = false
vim.o.modeline = false
vim.o.number = true
vim.o.relativenumber = false
vim.o.signcolumn = "no"
vim.o.laststatus = 0
vim.o.statusline = " "
vim.o.showtabline = 0
vim.o.cmdheight = 1
vim.o.showmode = false
vim.o.showcmd = false
vim.o.ruler = false
vim.o.autoindent = false
vim.o.smartindent = false
vim.o.expandtab = true
vim.o.tabstop = 2
vim.o.shiftwidth = 2
vim.o.shortmess = "filnxtToOFc"
vim.opt.diffopt = { "internal", "filler", "closeoff", "algorithm:histogram", "linematch:60", "context:30" }
vim.g.mapleader = " "
vim.cmd.colorscheme("dogrun")
vim.cmd("filetype on")
vim.cmd("syntax on")
require("nvim-web-devicons").setup()
vim.fn.chdir(repo)

local diffreel = require("diffreel")
diffreel.setup({ daemon = vim.env.DIFFREEL_DAEMON, auto_install = false, watch = scene == "live-update", width = 35 })

local before = vim.fn.readfile(run .. "/tapes/fixtures/before.lua")
local after = vim.fn.readfile(run .. "/tapes/fixtures/after.lua")
local draft = vim.deepcopy(after)
draft[10] = "  query = vim.trim(query):lower()"
local updated = vim.deepcopy(after)
updated[4] = '  local marks = { A = "+", M = "M" }'
local external = vim.deepcopy(updated)
external[5] = '  local mark = marks[file.status] or "?"'
local live_draft = vim.deepcopy(updated)
live_draft[10] = draft[10]
local view, draft_buf
local checkpoints = {}
local layout = scene == "layout-stacked" and "stacked" or scene == "layout-inline" and "inline" or "side_by_side"

local function same(buf, expected)
  return vim.api.nvim_buf_is_valid(buf) and vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expected)
end

local function ready(path)
  return view
    and view.ready
    and not view.updating
    and not view.inline_pending
    and not view.layout_pending
    and not view.error
    and view.selected_path == path
    and view.layout == layout
end

local function check(stage)
  local ok, err = pcall(function()
    assert(
      vim.wait(10000, function()
        if stage == "switched" then
          return ready("src/config.lua") and same(draft_buf, draft) and vim.bo[draft_buf].modified
        end
        if not ready("src/review.lua") or not same(view.left_buf, before) then
          return false
        end
        local wanted = stage == "start" and after
          or stage == "updated" and updated
          or scene == "live-update" and live_draft
          or draft
        local dirty = stage ~= "start" and stage ~= "updated"
        local disk = stage == "external" and external
          or scene == "live-update" and stage ~= "start" and updated
          or after
        return same(view.right_buf, wanted)
          and vim.bo[view.right_buf].modified == dirty
          and view.disk_conflict == dirty
          and vim.deep_equal(vim.fn.readfile(repo .. "/src/review.lua"), disk)
          and view.by_path[view.selected_path].right.content_id == vim.fn.sha256(table.concat(disk, "\n") .. "\n")
      end, 20),
      "Scene did not reach " .. stage
    )
    assert(#view.entries == 3, "Unexpected changed-file list")
    if stage == "draft" then
      draft_buf = view.right_buf
    elseif stage == "returned" then
      assert(view.right_buf == draft_buf, "File switching replaced the real buffer")
    end
    checkpoints[#checkpoints + 1] = stage
    vim.cmd("redraw!")
    print("DEMO_READY_" .. stage)
  end)
  if not ok then
    vim.fn.writefile({ tostring(err) }, run .. "/failure.txt")
    local failure = {
      stage = stage,
      selected = view and view.selected_path,
      layout = view and view.layout,
      ready = view and view.ready,
      updating = view and view.updating,
      conflict = view and view.disk_conflict,
      modified = view and vim.bo[view.right_buf].modified,
      buffer = view and vim.api.nvim_buf_get_lines(view.right_buf, 0, -1, false),
      disk = vim.fn.readfile(repo .. "/src/review.lua"),
      entry = view and view.by_path[view.selected_path],
    }
    vim.fn.writefile({ vim.json.encode(failure) }, run .. "/failure.json")
    vim.cmd("cquit 1")
  end
end

vim.api.nvim_create_user_command("DemoCheck", function(args)
  check(args.args)
end, { nargs = 1 })

vim.api.nvim_create_user_command("DemoWrite", function(args)
  local lines = args.args == "updated" and updated or external
  local writer = vim
    .system({ "sh", "-c", 'cat > "$1"', "demo-writer", repo .. "/src/review.lua" }, {
      stdin = table.concat(lines, "\n") .. "\n",
    })
    :wait()
  assert(writer.code == 0, "External writer failed")
end, { nargs = 1 })

vim.api.nvim_create_user_command("DemoFinish", function()
  local expected = scene == "review-edit" and { "start", "draft", "switched", "returned" }
    or scene == "live-update" and { "start", "updated", "draft", "external" }
    or { "start", "draft" }
  assert(vim.deep_equal(checkpoints, expected), "Incomplete recording")
  vim.fn.writefile({
    vim.json.encode({
      passed = true,
      scene = scene,
      checkpoints = checkpoints,
      layout = layout,
      columns = vim.o.columns,
      rows = vim.o.lines,
      plugin = debug.getinfo(diffreel.open, "S").source,
      daemon = diffreel.config.daemon,
    }),
  }, run .. "/verified.json")
  vim.cmd("qa!")
end, {})

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    view = diffreel.open({ selected_file = "src/review.lua", layout = layout })
    vim.schedule(function()
      check("start")
      if view and view.right_win then
        vim.api.nvim_set_current_win(view.right_win)
      end
    end)
  end,
})
