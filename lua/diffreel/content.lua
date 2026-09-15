local M = {}

function M.valid_utf8(text)
  local i = 1
  while i <= #text do
    local b = text:byte(i)
    local n, lower, upper = 0, 128, 191
    if b < 128 then
      n = 0
    elseif b >= 194 and b <= 223 then
      n = 1
    elseif b >= 224 and b <= 239 then
      n = 2
      lower = b == 224 and 160 or lower
      upper = b == 237 and 159 or upper
    elseif b >= 240 and b <= 244 then
      n = 3
      lower = b == 240 and 144 or lower
      upper = b == 244 and 143 or upper
    else
      return false
    end
    if i + n > #text then
      return false
    end
    for j = 1, n do
      local value = text:byte(i + j)
      if value < (j == 1 and lower or 128) or value > (j == 1 and upper or 191) then
        return false
      end
    end
    i = i + n + 1
  end
  return true
end

function M.limited(reason, mode, size)
  return { exists = true, kind = "limited", reason = reason, mode = mode, size = size or 0 }
end

function M.decode(raw, mode, limit)
  mode = mode or "100644"
  if raw == nil then
    return { exists = false, kind = "missing", mode = "000000", size = 0, lines = { "" }, endofline = false }
  end
  if #raw > (limit or 1048576) then
    return M.limited("too-large", mode, #raw)
  end
  if raw:find("\0", 1, true) then
    return M.limited("binary", mode, #raw)
  end
  if not M.valid_utf8(raw) then
    return M.limited("encoding", mode, #raw)
  end
  local bom = mode ~= "120000" and raw:sub(1, 3) == string.char(239, 187, 191)
  local text = bom and raw:sub(4) or raw
  local normalized, crlf_count = text:gsub("\r\n", "\n")
  local _, lf_count = normalized:gsub("\n", "")
  if normalized:find("\r", 1, true) or (crlf_count > 0 and crlf_count ~= lf_count) then
    return M.limited("mixed-newlines", mode, #raw)
  end
  local eol = normalized:sub(-1) == "\n"
  local lines = vim.split(normalized, "\n", { plain = true })
  if eol then
    table.remove(lines)
  end
  if #lines == 0 then
    lines = { "" }
  end
  return {
    exists = true,
    kind = mode == "120000" and "symlink" or "text",
    mode = mode,
    size = #raw,
    lines = lines,
    endofline = eol,
    fileformat = crlf_count > 0 and "dos" or "unix",
    bom = bom,
    content_id = vim.fn.sha256(raw),
  }
end

function M.same(left, right)
  return left.exists == right.exists
    and left.kind ~= "limited"
    and right.kind ~= "limited"
    and left.mode == right.mode
    and left.content_id == right.content_id
end

return M
