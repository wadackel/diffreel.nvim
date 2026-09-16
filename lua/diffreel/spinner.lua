local M = {}

M.defaults = { frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, interval = 80 }

local settings, animate, timer, index = M.defaults, nil, nil, 1

function M.configure(value)
  M.stop()
  settings = value == nil and M.defaults or value
end

function M.register(callback)
  animate = callback
end

function M.stop()
  if timer then
    local handle = timer
    timer = nil
    handle:stop()
    if not handle:is_closing() then
      handle:close()
    end
  end
  index = 1
end

local function wake()
  if timer or not animate then
    return
  end
  local handle = vim.uv.new_timer()
  timer = handle
  handle:start(
    settings.interval,
    settings.interval,
    vim.schedule_wrap(function()
      -- A scheduled callback can still run after stop() closed the handle it belonged to.
      if timer ~= handle then
        return
      end
      index = index + 1
      if not animate() then
        M.stop()
      end
    end)
  )
end

function M.frame()
  if settings == false then
    return nil
  end
  -- Starting the timer from the caller instead leaves a glyph frozen on screen whenever
  -- a new render site forgets the call, so the frame itself claims the clock.
  wake()
  return settings.frames[(index - 1) % #settings.frames + 1]
end

return M
