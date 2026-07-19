-- Capsium Lua Library
-- Minimal RFC 4180-style CSV parser (framework-agnostic, pure functions)

local _M = {
  _VERSION = "0.3.0"
}

-- Parse CSV text into an array of rows, each row an array of field strings.
-- Supports quoted fields, escaped double quotes (""), commas and newlines
-- inside quoted fields, and CRLF/LF line endings.
function _M.parse(text)
  if type(text) ~= "string" then
    return nil, "CSV input must be a string"
  end

  local rows = {}
  local row = {}
  local field = {}
  local in_quotes = false
  local pos = 1
  local len = #text

  local function flush_field()
    table.insert(row, table.concat(field))
    field = {}
  end

  local function flush_row()
    flush_field()
    table.insert(rows, row)
    row = {}
  end

  while pos <= len do
    local ch = text:sub(pos, pos)

    if in_quotes then
      if ch == '"' then
        if text:sub(pos + 1, pos + 1) == '"' then
          -- Escaped quote
          table.insert(field, '"')
          pos = pos + 1
        else
          in_quotes = false
        end
      else
        table.insert(field, ch)
      end
    elseif ch == '"' then
      in_quotes = true
    elseif ch == "," then
      flush_field()
    elseif ch == "\n" then
      flush_row()
    elseif ch ~= "\r" then
      -- \r is skipped (handled by the following \n or at end of input)
      table.insert(field, ch)
    end

    pos = pos + 1
  end

  if in_quotes then
    return nil, "Unterminated quoted field in CSV input"
  end

  -- Flush the final row when the input does not end with a newline.
  -- (#field > 0 or #row > 0) means there is pending content.
  if #field > 0 or #row > 0 then
    flush_row()
  end

  return rows
end

-- Parse CSV text with a header row into an array of objects
-- (one table per data row, keyed by the header fields).
function _M.to_objects(text)
  local rows, err = _M.parse(text)
  if not rows then
    return nil, err
  end

  if #rows == 0 then
    return {}
  end

  local header = rows[1]
  local objects = {}

  for i = 2, #rows do
    local obj = {}
    for j, key in ipairs(header) do
      obj[key] = rows[i][j]
    end
    table.insert(objects, obj)
  end

  return objects
end

return _M
