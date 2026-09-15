vim.opt.rtp:prepend(vim.fn.getcwd())
local failures, passed = {}, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end

test("statistics yield between pages and ignore obsolete requests", function()
  local stats = require("diffreel.line_stats")
  local requests, renders = {}, 0
  local backend = {
    request = function(_, method, params, callback)
      requests[#requests + 1] = { method = method, params = params, callback = callback }
    end,
  }
  local view = {
    alive = true,
    ready = true,
    line_stats = false,
    compare_seq = 1,
    manager = { backend = backend, session_id = "session" },
    comparison = { comparison_id = "one", generation = 1 },
  }
  local function valid(v)
    return v.alive
  end
  local function render()
    renders = renders + 1
  end
  stats.start(view, valid, render)
  assert(not view.statistics and #requests == 0)
  view.line_stats = true
  stats.start(view, valid, render)
  assert(#requests == 0, "Stats blocked the content-ready callback")
  stats.start(view, valid, render)
  assert(vim.wait(1000, function()
    return #requests == 1
  end, 5))
  assert(requests[1].method == "comparison/stats" and requests[1].params.offset == 0)
  requests[1].callback(nil, {
    session_id = "session",
    comparison_id = "one",
    generation = 1,
    files = { a = { additions = 2, deletions = 1 } },
    next_offset = 1,
    complete = false,
  })
  assert(vim.wait(1000, function()
    return #requests == 2
  end, 5))
  assert(requests[2].params.offset == 1)
  requests[2].callback(nil, {
    session_id = "session",
    comparison_id = "one",
    generation = 1,
    files = { b = { reason = "binary" } },
    next_offset = 2,
    complete = true,
  })
  assert(view.statistics.complete and view.statistics.additions == 2 and view.statistics.deletions == 1)
  assert(view.statistics.unavailable == 1)
  stats.start(view, valid, render)
  assert(#requests == 2, "Completed statistics restarted")
  view.comparison.generation = 2
  assert(not next(stats.files(view)), "Old-generation counts remained visible")
  stats.start(view, valid, render)
  assert(vim.wait(1000, function()
    return #requests == 3
  end, 5))
  local current = view.statistics
  requests[2].callback(nil, {
    session_id = "session",
    comparison_id = "one",
    generation = 1,
    files = { a = { additions = 99, deletions = 99 } },
    next_offset = 2,
    complete = true,
  })
  assert(view.statistics == current and not next(current.files))
  requests[3].callback("stats unavailable")
  assert(view.statistics.error and not view.error and view.ready)
  view.comparison.generation = 3
  stats.start(view, valid, render)
  assert(vim.wait(1000, function()
    return #requests == 4
  end, 5))
  view.alive = false
  local before = renders
  requests[4].callback(nil, {
    session_id = "session",
    comparison_id = "one",
    generation = 3,
    files = { a = { additions = 2, deletions = 1 } },
    next_offset = 1,
    complete = true,
  })
  vim.wait(30)
  assert(renders == before and not next(view.statistics.files), "Closed view accepted statistics")
end)

test("explorer row caching includes saved line counts", function()
  local explorer = require("diffreel.explorer")
  local entries = { { path = "a.lua", status = "modified", left = {}, right = {} } }
  local tree = explorer.build(entries)
  local plain = explorer.rows(entries, {}, 35, tree)
  local files = { ["a.lua"] = { additions = 12, deletions = 3 } }
  local rows = explorer.rows(entries, {}, 35, tree, files)
  assert(rows ~= plain and rows[1].text:find("+12 -3", 1, true))
  assert(explorer.rows(entries, {}, 35, tree, files) == rows)
  local binary = explorer.rows(entries, {}, 35, tree, { ["a.lua"] = { reason = "binary" } })
  assert(binary[1].text:find("bin", 1, true))
  assert(not explorer.rows(entries, {}, 35, tree)[1].text:find("bin", 1, true))
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
