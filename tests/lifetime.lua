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

local function fake_view()
  vim.cmd("tabnew")
  local right_win, right_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local left_buf = vim.api.nvim_create_buf(false, true)
  local left_win = vim.api.nvim_open_win(left_buf, false, { split = "left", win = right_win })
  local manager = { session_id = "session-1", backend = { closed = false } }
  return {
    alive = true,
    tab = vim.api.nvim_get_current_tabpage(),
    left_win = left_win,
    right_win = right_win,
    left_buf = left_buf,
    right_buf = right_buf,
    empty_buf = right_buf,
    explorer_buf = vim.api.nvim_create_buf(false, true),
    explorer_options = { visible = false },
    manager = manager,
    comparison = { comparison_id = "cmp-1", generation = 1 },
    selection_seq = 3,
    compare_seq = 2,
  }
end

local function with_view(body)
  local view = fake_view()
  local ok, err = xpcall(body, debug.traceback, view)
  pcall(vim.cmd, "tabclose!")
  assert(ok, err)
end

test("a fresh ticket is current for every scope", function()
  with_view(function(view)
    local lifetime = require("diffreel.lifetime")
    assert(lifetime.valid(view), "fake view should satisfy valid")
    for _, scope in ipairs({ "manager", "comparison", "selection" }) do
      assert(lifetime.current(view, lifetime.ticket(view, scope)), scope)
    end
  end)
end)

test("selection changes only invalidate selection tickets", function()
  with_view(function(view)
    local lifetime = require("diffreel.lifetime")
    local tickets = {
      manager = lifetime.ticket(view, "manager"),
      comparison = lifetime.ticket(view, "comparison"),
      selection = lifetime.ticket(view, "selection"),
    }
    view.selection_seq = view.selection_seq + 1
    assert(lifetime.current(view, tickets.manager))
    assert(lifetime.current(view, tickets.comparison))
    assert(not lifetime.current(view, tickets.selection))
    view.selection_seq = view.selection_seq - 1
    view.comparison = { comparison_id = "cmp-2", generation = 1 }
    assert(lifetime.current(view, tickets.comparison))
    assert(not lifetime.current(view, tickets.selection))
  end)
end)

test("comparison sequences invalidate only comparison tickets", function()
  with_view(function(view)
    local lifetime = require("diffreel.lifetime")
    local manager, comparison, selection =
      lifetime.ticket(view, "manager"), lifetime.ticket(view, "comparison"), lifetime.ticket(view, "selection")
    view.compare_seq = view.compare_seq + 1
    assert(lifetime.current(view, manager))
    assert(not lifetime.current(view, comparison))
    assert(lifetime.current(view, selection), "a failed comparison open must not strand an in-flight selection")
  end)
end)

test("manager replacement and session changes invalidate every scope", function()
  with_view(function(view)
    local lifetime = require("diffreel.lifetime")
    local tickets = {}
    for _, scope in ipairs({ "manager", "comparison", "selection" }) do
      tickets[scope] = lifetime.ticket(view, scope)
    end
    local original = view.manager
    view.manager = { session_id = "session-1", backend = { closed = false } }
    for scope, ticket in pairs(tickets) do
      assert(not lifetime.current(view, ticket), scope .. " survived a manager swap")
    end
    view.manager = original
    original.session_id = "session-2"
    for scope, ticket in pairs(tickets) do
      assert(not lifetime.current(view, ticket), scope .. " survived a session change")
    end
    original.session_id = "session-1"
    original.backend.closed = true
    for scope, ticket in pairs(tickets) do
      assert(lifetime.current(view, ticket), scope .. " must leave backend state to the caller")
    end
  end)
end)

test("a ticket captured without a comparison stays current until one appears", function()
  with_view(function(view)
    local lifetime = require("diffreel.lifetime")
    view.comparison = nil
    local ticket = lifetime.ticket(view, "selection")
    assert(lifetime.current(view, ticket))
    view.comparison = { comparison_id = "cmp-1", generation = 1 }
    assert(not lifetime.current(view, ticket))
  end)
end)

test("an invalid view is never current", function()
  with_view(function(view)
    local lifetime = require("diffreel.lifetime")
    local ticket = lifetime.ticket(view, "manager")
    vim.api.nvim_win_close(view.left_win, true)
    assert(not lifetime.valid(view))
    assert(not lifetime.current(view, ticket))
  end)
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
