local M = {}
local explorer = require("diffreel.explorer")
local hunks = require("diffreel.hunks")
M.scopes = { explorer = "n", diff = "n", diff_visual = "x", diff_operator = "o" }

local defaults = {
  explorer = {
    q = "close",
    ["g?"] = "show_help",
    R = "refresh",
    ["<CR>"] = "select_entry",
    ["<Leader>e"] = "focus_right",
    ["<Tab>"] = "next_file",
    ["<S-Tab>"] = "prev_file",
    ["<C-f>"] = "scroll_down",
    ["<C-b>"] = "scroll_up",
    ["<C-t>"] = "edit_file",
    ["<C-h>"] = "collapse_node",
    ["^"] = "parent",
    E = "expand_recursive",
    W = "collapse_recursive",
    gE = "expand_all",
    gW = "collapse_all",
    yp = "yank_path",
    yP = "yank_path_absolute",
    yn = "yank_name",
    i = "toggle_listing",
    I = "toggle_compact",
    K = "show_path",
    gL = "cycle_layout",
    ["<Leader>b"] = "toggle_explorer",
  },
  diff = {
    q = "close",
    ["g?"] = "show_help",
    ["<Leader>e"] = "focus_explorer",
    ["]f"] = "next_file",
    ["[f"] = "prev_file",
    ["<Leader>b"] = "toggle_explorer",
    ["]h"] = "next_hunk",
    ["[h"] = "prev_hunk",
    ["[H"] = "first_hunk",
    ["]H"] = "last_hunk",
    gL = "cycle_layout",
    ["]c"] = "next_change",
    ["[c"] = "prev_change",
  },
  diff_visual = { ih = "select_hunk" },
  diff_operator = { ih = "select_hunk" },
}

local function row(view)
  if not view.explorer_win or not vim.api.nvim_win_is_valid(view.explorer_win) then
    return
  end
  return view.rows[vim.api.nvim_win_get_cursor(view.explorer_win)[1] - 3]
end

local actions = {
  cycle_layout = function(ctx, api)
    api.cycle_layout(ctx.view)
  end,
  layout_side_by_side = function(ctx, api)
    api.set_layout(ctx.view, "side_by_side")
  end,
  layout_stacked = function(ctx, api)
    api.set_layout(ctx.view, "stacked")
  end,
  layout_inline = function(ctx, api)
    api.set_layout(ctx.view, "inline")
  end,
  next_change = function(ctx, api)
    api.next_change(ctx.view, ctx.count)
  end,
  prev_change = function(ctx, api)
    api.next_change(ctx.view, -ctx.count)
  end,
  next_hunk = function(ctx, api)
    api.next_hunk(ctx.view, ctx.count)
  end,
  prev_hunk = function(ctx, api)
    api.next_hunk(ctx.view, -ctx.count)
  end,
  first_hunk = function(ctx, api)
    api.first_hunk(ctx.view)
  end,
  last_hunk = function(ctx, api)
    api.last_hunk(ctx.view)
  end,
  select_hunk = function(ctx, api)
    api.select_hunk(ctx.view, ctx.count)
  end,
  show_help = function(ctx, api)
    api.show_help(ctx.view)
  end,
  show_path = function(ctx, api)
    local entry = row(ctx.view)
    if entry then
      api.show_path(ctx.view, entry.path)
    end
  end,
  close = function(ctx, api)
    api.close(ctx.view)
  end,
  refresh = function(ctx, api)
    api.refresh(ctx.view)
  end,
  next_file = function(ctx, api)
    api.next_file(ctx.view, ctx.count)
  end,
  prev_file = function(ctx, api)
    api.next_file(ctx.view, -ctx.count)
  end,
  focus_explorer = function(ctx, api)
    api.focus_explorer(ctx.view)
  end,
  toggle_explorer = function(ctx, api)
    api.toggle_explorer(ctx.view)
  end,
  toggle_listing = function(ctx, api)
    api.set_explorer(ctx.view, { mode = ctx.view.explorer_options.mode == "tree" and "list" or "tree" })
  end,
  toggle_compact = function(ctx, api)
    api.set_explorer(ctx.view, { compact = not ctx.view.explorer_options.compact })
  end,
  focus_right = function(ctx)
    vim.api.nvim_set_current_win(ctx.view.right_win)
  end,
  scroll_down = function(ctx, api)
    api.scroll(ctx.view, 1)
  end,
  scroll_up = function(ctx, api)
    api.scroll(ctx.view, -1)
  end,
  select_entry = function(ctx, api, render)
    local entry = row(ctx.view)
    if entry and entry.directory then
      local target = explorer.act(ctx.view.tree, ctx.view.collapsed, entry.path, "toggle", entry)
      render(ctx.view, target)
    elseif entry then
      api.select(ctx.view, entry.path)
    end
  end,
  edit_file = function(ctx, api)
    local entry = row(ctx.view)
    if entry and entry.entry then
      api.edit_file(ctx.view, entry.path)
    end
  end,
}

local explorer_only = { select_entry = true, edit_file = true, show_path = true }
for _, name in ipairs({
  "collapse_node",
  "parent",
  "expand_recursive",
  "collapse_recursive",
  "expand_all",
  "collapse_all",
}) do
  explorer_only[name] = true
  actions[name] = function(ctx, _, render)
    if ctx.view.explorer_options and ctx.view.explorer_options.mode == "list" then
      return
    end
    local entry = row(ctx.view)
    local target = explorer.act(ctx.view.tree, ctx.view.collapsed, entry and entry.path, name, entry)
    if target ~= nil then
      render(ctx.view, target)
    end
  end
end
for _, name in ipairs({ "yank_path", "yank_path_absolute", "yank_name" }) do
  explorer_only[name] = true
  actions[name] = function(ctx)
    local entry = row(ctx.view)
    if not entry then
      return
    end
    assert(vim.fn.has("clipboard") == 1, "Clipboard provider unavailable; configure Neovim's clipboard")
    local value = entry.path
    if name == "yank_name" then
      value = entry.name
    elseif name == "yank_path_absolute" then
      value = ctx.view.root:gsub("/$", "") .. "/" .. entry.path
    end
    -- Command providers can report failures separately while setreg() still returns zero.
    assert(vim.fn.setreg("+", value, "v") == 0, "Could not copy the path to the clipboard")
  end
end

local function sorted_keys(values)
  local result = {}
  for lhs in pairs(values) do
    assert(type(lhs) == "string" and lhs ~= "", "Keymap keys must be nonempty strings")
    result[#result + 1] = lhs
  end
  table.sort(result)
  return result
end

function M.resolve(opts)
  opts = opts == nil and {} or opts
  assert(type(opts) == "table", "diffreel: keymaps must be a table")
  for name in pairs(opts) do
    assert(name == "defaults" or defaults[name], "diffreel: unknown keymap option " .. tostring(name))
  end
  assert(opts.defaults == nil or type(opts.defaults) == "boolean", "diffreel: keymaps.defaults must be a boolean")
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, result = pcall(function()
    local resolved = {}
    local function native(lhs, mode)
      local callback = function() end
      vim.keymap.set(mode, lhs, callback, { buffer = buf })
      local mapping
      for _, candidate in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if candidate.callback == callback then
          mapping = candidate
          break
        end
      end
      assert(mapping, "Could not resolve keymap: " .. lhs)
      vim.keymap.del(mode, mapping.lhs, { buffer = buf })
      -- maparg().lhs loses literal '<' escapes; keycode() also simplifies distinct modifier mappings.
      return { lhs = mapping.lhs, raw = mapping.lhsraw, alternate = mapping.lhsrawalt, mode = mode }
    end
    for _, scope in ipairs({ "explorer", "diff", "diff_visual", "diff_operator" }) do
      local mode = M.scopes[scope]
      local overrides = opts[scope] == nil and {} or opts[scope]
      assert(type(overrides) == "table", "keymaps." .. scope .. " must be a table")
      local entries, seen = {}, {}
      if opts.defaults ~= false then
        for _, lhs in ipairs(sorted_keys(defaults[scope])) do
          local binding = native(lhs, mode)
          binding.action = defaults[scope][lhs]
          if scope == "diff" and (lhs == "]c" or lhs == "[c") then
            binding.inline_only = true
          end
          entries[binding.raw] = binding
        end
      end
      for _, lhs in ipairs(sorted_keys(overrides)) do
        local action = overrides[lhs]
        assert(action == false or type(action) == "function" or type(action) == "string", "Invalid action for " .. lhs)
        if type(action) == "string" then
          assert(actions[action], "Unknown keymap action: " .. action)
          assert(scope == "explorer" or not explorer_only[action], action .. " is only available in the explorer")
          assert(
            (mode == "n") == (action ~= "select_hunk"),
            "select_hunk requires a Visual/operator scope; other named actions require Normal mode"
          )
        end
        local binding = native(lhs, mode)
        assert(not binding.lhs:find("<Plug>(Diffreel", 1, true), "The <Plug>(Diffreel...) namespace is reserved")
        assert(not seen[binding.raw], "Duplicate keymap: " .. lhs .. " and " .. tostring(seen[binding.raw]))
        seen[binding.raw] = lhs
        binding.action = action
        entries[binding.raw] = action ~= false and binding or nil
      end
      resolved[scope] = vim.tbl_values(entries)
      table.sort(resolved[scope], function(a, b)
        return a.lhs < b.lhs
      end)
    end
    return resolved
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then
    error("diffreel: invalid keymaps: " .. tostring(result), 0)
  end
  return result
end

function M.bindings(policy, api, render)
  local result, alternates = {}, {}
  for _, binding in ipairs(policy) do
    local action = binding.action
    alternates[binding.lhs] = binding.alternate
    result[binding.lhs] = function(view, count)
      local ok, err = xpcall(function()
        local ctx = { view = view, count = count, mode = binding.mode }
        if type(action) == "function" then
          action(ctx)
        else
          actions[action](ctx, api, render)
        end
      end, debug.traceback)
      if not ok then
        vim.notify("diffreel: keymap " .. binding.lhs .. " failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
  end
  return result, alternates
end

function M.guards(policy)
  local result = {}
  for _, binding in ipairs(policy) do
    if binding.action == "select_hunk" then
      result[binding.lhs] = function(view)
        return hunks.eligible(view, vim.api.nvim_get_current_win())
      end
    end
  end
  return result
end

function M.conditions(policy)
  local result = {}
  for _, binding in ipairs(policy) do
    if binding.inline_only then
      result[binding.lhs] = function(view)
        return view.layout == "inline"
      end
    end
  end
  return result
end

return M
