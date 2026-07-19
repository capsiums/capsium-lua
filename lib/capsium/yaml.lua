-- Capsium Lua Library
-- Minimal block-style YAML parser for dataset documents
-- (framework-agnostic, pure functions)
--
-- Supports the subset used by Capsium dataset files:
--   * block mappings ("key: value" / "key:" + nested block)
--   * block sequences ("- scalar", "- key: value" + continuation lines)
--   * plain, single- and double-quoted scalars; integers, floats,
--     booleans and null
--   * comments and document markers (---)
-- Flow collections, anchors/aliases and block scalars (|, >) are NOT
-- supported and raise a parse error. Null mapping values and null
-- sequence items are dropped (Lua tables cannot hold nil).

local _M = {
  _VERSION = "0.4.0"
}

-- Parse a scalar token: quoted string, number, boolean, null or plain
-- string. Returns value | nil (null) | nil, err.
local function parse_scalar(text)
  local first = text:sub(1, 1)

  if first == '"' then
    if text:sub(-1) ~= '"' or #text < 2 then
      return nil, "unterminated double-quoted scalar: " .. text
    end
    local out = {}
    local i = 2
    while i < #text do
      local ch = text:sub(i, i)
      if ch == "\\" then
        local nxt = text:sub(i + 1, i + 1)
        local escapes = {
          n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\"
        }
        out[#out + 1] = escapes[nxt] or nxt
        i = i + 2
      else
        out[#out + 1] = ch
        i = i + 1
      end
    end
    return table.concat(out)
  end

  if first == "'" then
    if text:sub(-1) ~= "'" or #text < 2 then
      return nil, "unterminated single-quoted scalar: " .. text
    end
    return (text:sub(2, -2):gsub("''", "'"))
  end

  if text == "" or text == "~" or text:lower() == "null" then
    return nil
  end
  if text:lower() == "true" then
    return true
  end
  if text:lower() == "false" then
    return false
  end
  if text:match("^[+-]?%d+$") or text:match("^[+-]?%d+%.%d+$") then
    return tonumber(text)
  end

  return text
end

-- Split the document into significant lines ({ indent, text }), dropping
-- blank lines, comments and document markers.
local function significant_lines(content)
  local lines = {}

  for raw in (content .. "\n"):gmatch("(.-)\r?\n") do
    -- Strip a trailing comment outside quotes (# at start or after
    -- whitespace)
    local in_single, in_double = false, false
    local cut = #raw
    for i = 1, #raw do
      local ch = raw:sub(i, i)
      if ch == "'" and not in_double then
        in_single = not in_single
      elseif ch == '"' and not in_single then
        in_double = not in_double
      elseif ch == "#" and not in_single and not in_double
             and (i == 1 or raw:sub(i - 1, i - 1):match("%s")) then
        cut = i - 1
        break
      end
    end

    local indent, text = raw:sub(1, cut):match("^(%s*)(.-)%s*$")
    if text ~= "" and text ~= "---" and text ~= "..." then
      lines[#lines + 1] = { indent = #indent, text = text }
    end
  end

  return lines
end

local parse_block -- forward declaration

-- Parse a block mapping starting at lines[pos] (all entries at `indent`).
-- Returns map, next_pos | nil, err.
local function parse_mapping(lines, pos, indent)
  local map = {}

  while pos <= #lines and lines[pos].indent == indent do
    local text = lines[pos].text
    if text:sub(1, 1) == "-" then
      return nil, "sequence entry inside a mapping: " .. text
    end

    local key, value = text:match("^([^:]+):%s*(.-)%s*$")
    if not key or key == "" then
      return nil, "invalid mapping line: " .. text
    end
    pos = pos + 1

    if value == "" then
      if pos <= #lines and lines[pos].indent > indent then
        local child, err
        child, pos, err = parse_block(lines, pos, lines[pos].indent)
        if not child then
          return nil, err
        end
        map[key] = child
      end
      -- no nested block: null value (dropped, subset limitation)
    else
      local scalar, err = parse_scalar(value)
      if scalar == nil and err then
        return nil, err
      end
      map[key] = scalar
    end
  end

  return map, pos
end

-- Parse a block sequence starting at lines[pos] (all dashes at `indent`).
-- Returns array, next_pos | nil, err.
local function parse_sequence(lines, pos, indent)
  local seq = {}

  while pos <= #lines and lines[pos].indent == indent do
    local text = lines[pos].text
    local rest = text:match("^%-%s*(.-)%s*$")
    if not rest then
      return nil, "invalid sequence line: " .. text
    end
    pos = pos + 1

    if rest == "" then
      -- "- " with the item nested on the following, deeper lines
      if pos <= #lines and lines[pos].indent > indent then
        local child, err
        child, pos, err = parse_block(lines, pos, lines[pos].indent)
        if not child then
          return nil, err
        end
        seq[#seq + 1] = child
      end
    elseif rest:match("^[^:]+:%s") or rest:match("^[^:]+:$") then
      -- "- key: value": an inline mapping start; the item continues on
      -- following lines indented at or beyond the key's column
      local key_indent = indent + #(text:match("^%-%s*"))
      local synthetic = { { indent = key_indent, text = rest } }
      while pos <= #lines and lines[pos].indent >= key_indent do
        synthetic[#synthetic + 1] = lines[pos]
        pos = pos + 1
      end

      local item, next_pos, err = parse_block(synthetic, 1, key_indent)
      if not item then
        return nil, err
      end
      if next_pos <= #synthetic then
        return nil, "could not parse sequence item: " .. text
      end
      seq[#seq + 1] = item
    else
      local scalar, err = parse_scalar(rest)
      if scalar == nil and err then
        return nil, err
      end
      seq[#seq + 1] = scalar
    end
  end

  return seq, pos
end

-- Dispatch on the first line of a block: sequence when it starts with
-- "- ", mapping otherwise.
parse_block = function(lines, pos, indent)
  if pos > #lines then
    return nil, "unexpected end of document"
  end
  if lines[pos].text:match("^%-%s") or lines[pos].text == "-" then
    return parse_sequence(lines, pos, indent)
  end
  return parse_mapping(lines, pos, indent)
end

-- Parse a YAML document into Lua tables. Returns value | nil, err.
function _M.parse(content)
  if type(content) ~= "string" then
    return nil, "YAML input must be a string"
  end
  if content:find("\t") then
    return nil, "YAML with tab indentation is not supported"
  end

  local lines = significant_lines(content)
  if #lines == 0 then
    return nil, "empty YAML document"
  end

  local value, pos, err = parse_block(lines, 1, lines[1].indent)
  if not value then
    return nil, err
  end
  if pos <= #lines then
    return nil, "could not parse YAML near: " .. lines[pos].text
  end

  return value
end

return _M
