local failures, passed = {}, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
  else
    failures[#failures + 1] = name .. ": " .. err
  end
end

local function module_name(path)
  return path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
end

local function dependencies()
  local graph = {}
  for _, path in ipairs(vim.fn.globpath("lua/diffreel", "**/*.lua", false, true)) do
    local file = assert(io.open(path, "rb"))
    local source = file:read("*a")
    file:close()
    local edges = {}
    for target in source:gmatch([=[require%(?['"](diffreel[%w_%.]*)['"]]=]) do
      edges[#edges + 1] = target
    end
    graph[module_name(path)] = edges
  end
  return graph
end

local function find_cycle(graph)
  local state, stack = {}, {}
  local function visit(node)
    if state[node] == "done" then
      return nil
    end
    if state[node] == "active" then
      local start
      for index, name in ipairs(stack) do
        if name == node then
          start = index
          break
        end
      end
      return vim.list_slice(stack, start, #stack)
    end
    state[node] = "active"
    stack[#stack + 1] = node
    for _, target in ipairs(graph[node] or {}) do
      local cycle = visit(target)
      if cycle then
        return cycle
      end
    end
    stack[#stack] = nil
    state[node] = "done"
    return nil
  end
  local names = vim.tbl_keys(graph)
  table.sort(names)
  for _, name in ipairs(names) do
    local cycle = visit(name)
    if cycle then
      cycle[#cycle + 1] = cycle[1]
      return cycle
    end
  end
  return nil
end

test("plugin modules require each other without cycles", function()
  local graph = dependencies()
  for _, name in ipairs({
    "diffreel",
    "diffreel.layout",
    "diffreel.windows",
    "diffreel.render",
    "diffreel.manager",
    "diffreel.buffers",
    "diffreel.events",
  }) do
    assert(graph[name], "expected " .. name .. " in the module graph")
  end
  local cycle = find_cycle(graph)
  assert(cycle == nil, "require cycle: " .. table.concat(cycle or {}, " -> "))
end)

for _, err in ipairs(failures) do
  io.stderr:write(err .. "\n")
end
print(vim.json.encode({ passed = passed, failed = #failures }))
vim.cmd(#failures == 0 and "qa!" or "cquit 1")
