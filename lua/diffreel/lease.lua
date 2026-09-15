local M = { buffers = {} }

local function native_index(mappings)
  local result = {}
  for _, mapping in ipairs(mappings) do
    result[mapping.lhsraw] = mapping
  end
  for _, mapping in ipairs(mappings) do
    if mapping.lhsrawalt then
      result[mapping.lhsrawalt] = result[mapping.lhsrawalt] or mapping
    end
  end
  return result
end

function M.preserve_buffer(buf, action)
  local guard
  if buf and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
    -- A persistent handler would also suppress warnings in ordinary editing windows.
    guard = vim.api.nvim_create_autocmd("FileChangedShell", {
      buffer = buf,
      callback = function()
        vim.v.fcs_choice = ""
      end,
    })
  end
  local ok, value = pcall(action)
  if guard then
    pcall(vim.api.nvim_del_autocmd, guard)
  end
  if not ok then
    error(value, 0)
  end
  return value
end

local function install_mode(buf, lease, maps, mode, current, actions, alternates, guards, conditions)
  vim.api.nvim_buf_call(buf, function()
    local index, originals, fallbacks = 0, {}, {}
    local native = native_index(vim.api.nvim_buf_get_keymap(buf, mode))
    local keys = vim.tbl_keys(actions)
    table.sort(keys)
    for _, lhs in ipairs(keys) do
      local original = vim.fn.maparg(lhs, mode, false, true)
      -- maparg() describes an alternate as a separate mapping, losing its native pairing.
      if original.buffer == 1 and native[original.lhsraw] then
        original = vim.deepcopy(native[original.lhsraw])
        original.buffer = 1
      end
      originals[lhs] = original
      fallbacks[lhs] = original
      if not next(originals[lhs]) and alternates and alternates[lhs] then
        fallbacks[lhs] = vim.fn.maparg(vim.fn.keytrans(alternates[lhs]), mode, false, true)
      end
    end
    local function owned_view(lhs)
      local view = current()
      if
        M.buffers[buf] == lease
        and view
        and lease.owners[view.id]
        and (not conditions or not conditions[lhs] or conditions[lhs](view))
      then
        return view
      end
    end
    local function paired_alternate(mapping, globals)
      local raw = mapping.lhsrawalt
      if not raw then
        return false
      end
      local alternate = native_index(vim.api.nvim_buf_get_keymap(buf, mode))[raw]
      local local_map = alternate ~= nil
      if alternate then
        for key, value in pairs(maps) do
          if alternate.callback == value.dispatch then
            alternate = fallbacks[key]
            local_map = alternate.buffer == 1
            if not local_map then
              alternate = nil
            end
            break
          end
        end
      end
      if not alternate then
        alternate = (globals or native_index(vim.api.nvim_get_keymap(mode)))[raw]
        local_map = false
      end
      return alternate ~= nil and alternate.lhsraw == mapping.lhsraw and local_map == (mapping.buffer == 1)
    end
    for _, lhs in ipairs(keys) do
      local action, original = actions[lhs], originals[lhs]
      local alias, action_alias, literal_alias
      repeat
        index = index + 1
        alias = ("<Plug>(DiffreelFallback-%s%d-%d)"):format(mode == "n" and "" or (mode .. "-"), buf, index)
        action_alias = ("<Plug>(DiffreelAction-%s%d-%d)"):format(mode == "n" and "" or (mode .. "-"), buf, index)
        literal_alias = ("<Plug>(DiffreelLiteral-%s%d-%d)"):format(mode == "n" and "" or (mode .. "-"), buf, index)
      until next(vim.fn.maparg(alias, mode, false, true)) == nil
        and next(vim.fn.maparg(action_alias, mode, false, true)) == nil
        and next(vim.fn.maparg(literal_alias, mode, false, true)) == nil
      local fallback = fallbacks[lhs]
      local paired = paired_alternate(fallback)
      local installed_alias, installed_literal
      local function install_fallback(mapping, paired)
        local rhs = mapping.callback or mapping.rhs or lhs
        if type(rhs) == "string" and mapping.sid then
          rhs = rhs:gsub("<SID>", "<SNR>" .. mapping.sid .. "_")
        end
        local replace_keycodes = mapping.replace_keycodes == 1
        if mapping.noremap == 0 then
          local prefix = mapping.lhsraw
          -- Moving a recursive RHS to a Plug loses Neovim's literal leading-LHS rule.
          vim.keymap.set(mode, literal_alias, vim.fn.keytrans(prefix), { buffer = buf })
          installed_literal = vim.fn.maparg(literal_alias, mode, false, true)
          local function prefix_length(raw)
            if raw:sub(1, #prefix) == prefix then
              return #prefix
            end
            local alternate = paired and mapping.lhsrawalt
            if alternate and raw:sub(1, #alternate) == alternate then
              return #alternate
            end
          end
          local function preserve_prefix(raw)
            local length = prefix_length(raw)
            if length then
              return vim.keycode(literal_alias) .. raw:sub(length + 1)
            end
            return raw
          end
          if mapping.expr == 1 then
            local expression = rhs
            rhs = function()
              local value
              if type(expression) == "function" then
                value = expression()
              else
                value = vim.fn.eval(expression)
              end
              value = value == nil and "" or tostring(value)
              return preserve_prefix(mapping.replace_keycodes == 1 and vim.keycode(value) or value)
            end
            replace_keycodes = false
          elseif type(rhs) == "string" then
            local raw = vim.keycode(rhs)
            if prefix_length(raw) then
              rhs = vim.fn.keytrans(preserve_prefix(raw))
            end
          end
        end
        vim.keymap.set(mode, alias, rhs, {
          buffer = buf,
          remap = mapping.noremap == 0,
          script = mapping.script == 1,
          expr = mapping.expr == 1,
          replace_keycodes = replace_keycodes,
          silent = mapping.silent == 1,
        })
        installed_alias = vim.fn.maparg(alias, mode, false, true)
      end
      install_fallback(fallback, paired)
      local run = function()
        local view = owned_view(lhs)
        if view then
          action(view, vim.v.count1)
        end
      end
      vim.keymap.set(mode, action_alias, run, { buffer = buf, silent = true })
      local dispatch_raw
      local dispatch = function()
        -- Scheduled actions let subsequent typeahead run in the previous window.
        local view = owned_view(lhs)
        if view then
          if guards and guards[lhs] and not guards[lhs](view) then
            return mode == "o" and vim.keycode("<Esc>") or ""
          end
          return vim.keycode(action_alias)
        end
        local mapping, globals = fallback, nil
        if fallbacks[lhs].buffer ~= 1 then
          globals = native_index(vim.api.nvim_get_keymap(mode))
          mapping = globals[dispatch_raw] or (alternates and globals[alternates[lhs]]) or {}
        end
        local now_paired = paired_alternate(mapping, globals)
        if not vim.deep_equal(mapping, fallback) or now_paired ~= paired then
          install_fallback(mapping, now_paired)
          fallback, paired = mapping, now_paired
          maps[lhs].installed_alias = installed_alias
          maps[lhs].installed_literal = installed_literal
        end
        return vim.keycode(alias)
      end
      vim.keymap.set(
        mode,
        lhs,
        dispatch,
        { buffer = buf, expr = true, remap = true, replace_keycodes = false, nowait = false, silent = true }
      )
      dispatch_raw = vim.fn.maparg(lhs, mode, false, true).lhsraw
      maps[lhs] = {
        original = original,
        dispatch = dispatch,
        alias = alias,
        installed_alias = installed_alias,
        literal_alias = literal_alias,
        installed_literal = installed_literal,
        action_alias = action_alias,
        action = run,
      }
    end
  end)
end

function M.acquire(buf, owner, current, actions, alternates, modes, conditions)
  local lease = M.buffers[buf]
  if lease then
    lease.owners[owner] = true
    return
  end
  lease = { owners = { [owner] = true }, maps = {}, mode_maps = {}, options = {} }
  M.buffers[buf] = lease
  for name, value in pairs({ bufhidden = "hide", autoread = true }) do
    lease.options[name] = { original = vim.bo[buf][name], installed = value }
    vim.bo[buf][name] = value
  end
  install_mode(buf, lease, lease.maps, "n", current, actions, alternates, nil, conditions)
  for _, mode in ipairs({ "x", "o" }) do
    local policy = modes and modes[mode]
    if policy then
      local maps = {}
      lease.mode_maps[mode] = maps
      install_mode(buf, lease, maps, mode, current, policy.actions, policy.alternates, policy.guards)
    end
  end
end

function M.release(buf, owner)
  local lease = M.buffers[buf]
  if not lease then
    return
  end
  lease.owners[owner] = nil
  if next(lease.owners) then
    return
  end
  M.buffers[buf] = nil
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local failures = {}
  local function restore(action)
    local ok, err = pcall(action)
    if not ok then
      failures[#failures + 1] = tostring(err)
    end
  end
  for _, mode in ipairs({ "n", "x", "o" }) do
    local maps = mode == "n" and lease.maps or lease.mode_maps[mode] or {}
    restore(function()
      vim.api.nvim_buf_call(buf, function()
        local dispatches, primary, released, originals = {}, {}, {}, {}
        for _, value in pairs(maps) do
          dispatches[value.dispatch] = true
        end
        local mappings = vim.api.nvim_buf_get_keymap(buf, mode)
        local before = native_index(mappings)
        for _, mapping in ipairs(mappings) do
          primary[mapping.lhsraw] = mapping
        end
        local keys = vim.tbl_keys(maps)
        table.sort(keys)
        for _, lhs in ipairs(keys) do
          local value = maps[lhs]
          restore(function()
            local current = vim.fn.maparg(lhs, mode, false, true)
            local installed = before[current.lhsraw]
            if installed and installed.callback == value.dispatch then
              vim.api.nvim_buf_del_keymap(buf, mode, lhs)
              released[installed.lhsraw] = true
              if installed.lhsrawalt then
                released[installed.lhsrawalt] = true
              end
              if value.original.buffer == 1 then
                originals[value.original.lhsraw] = value.original
              end
            end
          end)
        end
        local remaining = native_index(vim.api.nvim_buf_get_keymap(buf, mode))
        for _, raw in ipairs(vim.fn.sort(vim.tbl_keys(originals))) do
          restore(function()
            local original, current = originals[raw], primary[raw]
            if not current then
              return
            end
            local restored = vim.deepcopy(dispatches[current.callback] and original or current)
            restored.buffer = 1
            -- Restoring only the alternate splits its pairing; replaying the old primary loses later replacements.
            if original.lhsrawalt and released[original.lhsrawalt] and not remaining[original.lhsrawalt] then
              restored.lhsrawalt = original.lhsrawalt
            elseif original.lhsrawalt and not remaining[original.lhsrawalt] then
              restored.lhsrawalt = nil
            elseif
              restored.lhsrawalt
              and remaining[restored.lhsrawalt]
              and remaining[restored.lhsrawalt].lhsraw ~= raw
            then
              restored.lhsrawalt = nil
            end
            vim.fn.mapset(mode, false, restored)
          end)
        end
        for _, lhs in ipairs(keys) do
          local value = maps[lhs]
          restore(function()
            local alias = vim.fn.maparg(value.alias, mode, false, true)
            if alias.callback == value.installed_alias.callback and alias.rhs == value.installed_alias.rhs then
              vim.api.nvim_buf_del_keymap(buf, mode, value.alias)
            end
          end)
          restore(function()
            if vim.fn.maparg(value.action_alias, mode, false, true).callback == value.action then
              vim.api.nvim_buf_del_keymap(buf, mode, value.action_alias)
            end
          end)
          restore(function()
            if value.installed_literal then
              local literal = vim.fn.maparg(value.literal_alias, mode, false, true)
              if
                literal.rhs == value.installed_literal.rhs and literal.callback == value.installed_literal.callback
              then
                vim.api.nvim_buf_del_keymap(buf, mode, value.literal_alias)
              end
            end
          end)
        end
      end)
    end)
  end
  for name, value in pairs(lease.options) do
    restore(function()
      if vim.bo[buf][name] == value.installed then
        vim.bo[buf][name] = value.original
      end
    end)
  end
  if #failures > 0 then
    error(table.concat(failures, "\n"), 0)
  end
end

return M
