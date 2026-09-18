local M = {}
local cache = {}
local flags = {
  "--cached",
  "--staged",
  "--unstaged",
  "--merge-base",
  "--stat",
  "--no-stat",
  "--untracked=all",
  "--untracked=no",
  "--no-untracked",
  "--exclude=",
  "--selected-file=",
  "--file",
  "--file=",
  "--pr=",
  "--layout=",
  "--list",
  "--tree",
  "--compact",
  "--no-compact",
  "--explorer",
  "--no-explorer",
  "--explorer-position=",
  "--repo=",
  "--help",
  "--",
}

local function words(text)
  local result, word, escaped = {}, "", false
  for i = 1, #text do
    local char = text:sub(i, i)
    if escaped then
      word, escaped = word .. char, false
    elseif char == "\\" then
      escaped = true
    elseif char:match("%s") then
      if word ~= "" then
        result[#result + 1], word = word, ""
      end
    else
      word = word .. char
    end
  end
  if escaped then
    word = word .. "\\"
  end
  if word ~= "" then
    result[#result + 1] = word
  end
  return result
end

local function matching(values, lead, prefix)
  local result = {}
  for _, value in ipairs(values) do
    if value:sub(1, #lead) == lead then
      result[#result + 1] = (prefix or "") .. value
    end
  end
  table.sort(result)
  return result
end

local function refs(root)
  if not root then
    return {}
  end
  local now = vim.uv.hrtime()
  local entry = cache[root]
  if entry and (entry.process or now - entry.at < 60e9) then
    return entry.names
  end
  if not entry and vim.tbl_count(cache) >= 16 then
    local oldest
    for key, value in pairs(cache) do
      if not oldest or value.at < cache[oldest].at then
        oldest = key
      end
    end
    if cache[oldest].process then
      pcall(cache[oldest].process.kill, cache[oldest].process, 15)
    end
    cache[oldest] = nil
  end
  entry = { at = now, names = entry and entry.names or {} }
  cache[root] = entry
  local ok, process = pcall(
    vim.system,
    { "git", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes", "refs/tags" },
    { cwd = root, text = true, timeout = 2000 },
    vim.schedule_wrap(function(result)
      if cache[root] ~= entry then
        return
      end
      entry.process = nil
      if result.code == 0 then
        entry.names = vim.split(result.stdout or "", "\n", { plain = true, trimempty = true })
      end
    end)
  )
  if ok then
    entry.process = process
  end
  return entry.names
end

local function files(root, lead, prefix)
  local absolute = lead:sub(1, 1) == "/"
  local query = absolute and lead or root:gsub("/$", "") .. "/" .. lead
  local result = {}
  for _, path in ipairs(vim.fn.getcompletion(query, "file")) do
    if not absolute then
      path = path:sub(#root:gsub("/$", "") + 2)
    end
    result[#result + 1] = (prefix or "") .. vim.fn.fnameescape(path)
  end
  return result
end

function M.complete(arglead, cmdline, cursorpos, review_root)
  local args = words(cmdline:sub(1, cursorpos))
  if arglead ~= "" then
    table.remove(args)
  end
  local supplied, after_paths, previous
  for i, value in ipairs(args) do
    if value == "--" then
      after_paths = true
      break
    elseif value == "--repo" or value == "-C" then
      supplied = args[i + 1]
    elseif value:sub(1, 7) == "--repo=" then
      supplied = value:sub(8)
    end
    previous = value
  end
  local lead = arglead:gsub("\\(.)", "%1")
  local name, partial = lead:match("^(%-%-[%w-]+=)(.*)$")
  if after_paths then
    name, partial, previous = nil, nil, nil
  end
  if name == "--untracked=" or previous == "--untracked" then
    return matching({ "all", "no" }, partial or lead, name)
  end
  if name == "--layout=" or previous == "--layout" then
    return matching({ "side_by_side", "stacked", "inline" }, partial or lead, name)
  end
  if name == "--pr=" or previous == "--pr" then
    return {}
  end
  if name == "--explorer-position=" or previous == "--explorer-position" then
    return matching({ "left", "right", "top", "bottom" }, partial or lead, name)
  end
  local path_option = name == "--selected-file="
    or name == "--file="
    or name == "--exclude="
    or name == "--repo="
    or previous == "--selected-file"
    or previous == "--exclude"
    or previous == "--repo"
    or previous == "-C"
  if args[1] == "DiffreelPRCacheClear" and not path_option then
    return matching({ "--repo=", "-C" }, lead)
  elseif not after_paths and not path_option and lead:sub(1, 1) == "-" then
    return matching(flags, lead)
  end
  local root = supplied and vim.fs.root(supplied, { ".git" })
    or review_root
    or vim.fs.root(vim.api.nvim_buf_get_name(0), { ".git" })
    or vim.fs.root(vim.fn.getcwd(), { ".git" })
  if after_paths or path_option then
    local directory = (name == "--repo=" or previous == "--repo" or previous == "-C") and vim.fn.getcwd()
      or root
      or vim.fn.getcwd()
    return files(directory, partial or lead, name)
  end
  local prefix, suffix = lead:match("^(.-%.%.%.)(.*)$")
  local values = { "HEAD" }
  if not prefix then
    vim.list_extend(values, { "worktree", ":0" })
  end
  vim.list_extend(values, refs(root and (vim.uv.fs_realpath(root) or root)))
  return matching(values, suffix or lead, prefix)
end

function M.shutdown()
  local pending = cache
  cache = {}
  for _, entry in pairs(pending) do
    if entry.process then
      pcall(entry.process.kill, entry.process, 15)
    end
  end
end

return M
