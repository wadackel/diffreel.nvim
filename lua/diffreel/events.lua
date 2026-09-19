local lifetime = require("diffreel.lifetime")
local valid = lifetime.valid
local M = {}

local function emit(view, name, details)
  local comparison = view.comparison
  local data = vim.tbl_extend("force", {
    view_id = view.id,
    root = view.root,
    path = view.selected_path,
    comparison_id = comparison and comparison.comparison_id,
    generation = comparison and comparison.generation,
  }, details or {})
  local ok, err =
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "Diffreel" .. name, modeline = false, data = data })
  if not ok then
    vim.schedule(function()
      vim.notify("diffreel: " .. name .. " hook failed: " .. tostring(err), vim.log.levels.ERROR)
    end)
  end
end

local function enter(view)
  if view.opened and not view.entered and valid(view) and vim.api.nvim_get_current_tabpage() == view.tab then
    view.entered = true
    emit(view, "Enter")
  end
end

local function leave(view)
  view.pending_hunk = nil
  if view.entered then
    view.entered = false
    emit(view, "Leave")
  end
end

M.emit, M.enter, M.leave = emit, enter, leave

return M
