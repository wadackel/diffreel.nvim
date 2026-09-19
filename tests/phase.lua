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
local function eq(expected, actual, label)
  assert(vim.deep_equal(expected, actual), (label or "") .. vim.inspect({ expected = expected, actual = actual }))
end

test("each transition writes exactly its flag tuple", function()
  local phase = require("diffreel.phase")
  local expectations = {
    { "switching", nil, { switching = true, updating = true } },
    { "answered", nil, { switching = false } },
    { "received", nil, { switching = false, ready = false, selection_pending = false } },
    { "selecting", nil, { ready = false, selection_pending = true, navigation = false } },
    { "ready", nil, { ready = true, selection_pending = false }, { "error" } },
    { "empty", nil, { ready = true, selection_pending = false } },
    { "paused", nil, { navigation = true } },
    { "resumed", nil, { navigation = false, ready = false, selection_pending = false } },
    { "failed", "blob read failed", { error = "blob read failed", selection_pending = false } },
    { "stopped", "daemon exited", { error = "daemon exited", updating = false } },
    { "retrying", nil, { updating = true }, { "error" } },
    { "closing", nil, { closing = true } },
    { "reopened", nil, { closing = false } },
    { "disposed", nil, { alive = false } },
  }
  local seed = {
    selected_path = "keep",
    comparison = { comparison_id = "keep" },
    alive = "seed",
    ready = "seed",
    error = "seed",
    updating = "seed",
    switching = "seed",
    closing = "seed",
    navigation = "seed",
    selection_pending = "seed",
  }
  for _, case in ipairs(expectations) do
    local name, detail, expected, cleared = case[1], case[2], case[3], case[4] or {}
    local view = vim.deepcopy(seed)
    phase.enter(view, name, detail)
    local wanted = vim.tbl_extend("force", vim.deepcopy(seed), expected)
    for _, field in ipairs(cleared) do
      wanted[field] = nil
    end
    eq(wanted, view, name .. ": ")
  end
end)

test("ready and retrying clear a previous error", function()
  local phase = require("diffreel.phase")
  local view = { error = "old", selection_pending = true }
  phase.enter(view, "ready")
  eq({ ready = true, selection_pending = false }, view)
  view = { error = "old", ready = true }
  phase.enter(view, "retrying")
  eq({ ready = true, updating = true }, view)
end)

test("stopped leaves switching and selection_pending to their own transitions", function()
  local phase = require("diffreel.phase")
  local view = { switching = true, selection_pending = true, updating = true }
  phase.enter(view, "stopped", "backend closed")
  eq({ switching = true, selection_pending = true, updating = false, error = "backend closed" }, view)
  phase.enter(view, "failed", "blob missing")
  eq({ switching = true, selection_pending = false, updating = false, error = "blob missing" }, view)
end)

test("unknown phases are rejected", function()
  local phase = require("diffreel.phase")
  local ok, err = pcall(phase.enter, {}, "redy")
  assert(not ok and tostring(err):find("unknown view phase", 1, true), tostring(err))
end)

test("predicates return booleans that follow the flag truth table", function()
  local phase = require("diffreel.phase")
  eq(true, phase.settled({ ready = true }))
  eq(false, phase.settled({ ready = true, updating = true }))
  eq(false, phase.settled({ ready = true, error = "x" }))
  eq(false, phase.settled({}))
  eq(true, phase.selected({ ready = true }))
  eq(false, phase.selected({ ready = true, selection_pending = true }))
  eq(false, phase.selected({}))
  eq(true, phase.has_content({ selection_pending = true }))
  eq(true, phase.has_content({ ready = true }))
  eq(false, phase.has_content({}))
  eq(true, phase.interactive({ ready = true }))
  eq(false, phase.interactive({ ready = true, navigation = true }))
  eq(false, phase.interactive({ ready = true, selection_pending = true }))
  eq(false, phase.interactive({}))
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
