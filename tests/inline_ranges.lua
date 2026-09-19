vim.opt.rtp:prepend(vim.fn.getcwd())
local inline = require("diffreel.inline")
local layout = require("diffreel.layout")
local presentation = require("diffreel.presentation")
local windows = require("diffreel.windows")
local api = vim.api
local failures, passed = {}, 0
math.randomseed(41207)
local values = { "a", "b", "x y", "xy", " ", "", "同じ", "different" }
local function run(flags, left, right)
  vim.o.diffopt = flags
  vim.cmd.tabnew()
  local rw, rb = api.nvim_get_current_win(), api.nvim_get_current_buf()
  vim.bo[rb].buftype = "nofile"
  api.nvim_buf_set_lines(rb, 0, -1, false, right)
  local lb = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(lb, 0, -1, false, left)
  local lw = api.nvim_open_win(lb, false, { split = "left", win = rw })
  local v = {
    alive = true,
    layout = "side_by_side",
    tab = api.nvim_get_current_tabpage(),
    left_buf = lb,
    right_buf = rb,
    empty_buf = rb,
    left_win = lw,
    right_win = rw,
    selected_path = "file",
    selection_seq = 1,
    by_path = { file = { left = { kind = "text", size = 10 }, right = { kind = "text", size = 10 } } },
  }
  local ok, err = xpcall(function()
    for _, win in ipairs({ lw, rw }) do
      api.nvim_win_call(win, function()
        vim.cmd.diffthis()
      end)
    end
    layout.apply(v, "inline")
    local done, failure, cache
    inline.compute(v, windows.engine_windows(v), function()
      return v.alive
    end, function(e, result)
      done, failure, cache = true, e, result
    end)
    assert(vim.wait(5000, function()
      return done
    end, 1))
    assert(not failure, failure)
    for side, win in ipairs(windows.engine_windows(v)) do
      api.nvim_win_call(win, function()
        for row = 1, api.nvim_buf_line_count(0) do
          assert(
            (cache[side == 1 and "left" or "right"][row] ~= nil) == (vim.fn.diff_hlID(row, 1) > 0),
            "Native row mismatch"
          )
        end
      end)
    end
    local previous = 0
    for _, block in ipairs(cache.deletions) do
      assert(block.after >= previous and block.after <= #right)
      previous = block.after
      local row = 0
      for _, item in ipairs(block.lines) do
        assert(item.row > row)
        row = item.row
      end
    end
  end, debug.traceback)
  inline.dispose(v)
  presentation.dispose(v)
  layout.dispose(v)
  v.alive = false
  vim.cmd("tabclose!")
  api.nvim_buf_delete(lb, { force = true })
  api.nvim_buf_delete(rb, { force = true })
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = flags .. ": " .. err
  end
end
for _, algorithm in ipairs({ "myers", "minimal", "patience", "histogram" }) do
  for _, whitespace in ipairs({ "", ",iwhite", ",iwhiteall", ",iwhiteeol" }) do
    for _, blank in ipairs({ "", ",iblank" }) do
      for _, refine in ipairs({ "", ",linematch:40" }) do
        for _ = 1, 10 do
          local left, right = { "top" }, { "top" }
          for _ = 1, math.random(1, 8) do
            left[#left + 1] = values[math.random(#values)]
          end
          for _ = 1, math.random(1, 8) do
            right[#right + 1] = values[math.random(#values)]
          end
          left[#left + 1], right[#right + 1] = "end", "end"
          run("internal,filler,context:2,algorithm:" .. algorithm .. whitespace .. blank .. refine, left, right)
        end
      end
    end
  end
end
for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
