-- Capsium Lua Library
-- Utility functions (framework-agnostic)

local _M = {
  _VERSION = "0.3.0"
}

local lfs = require "lfs"

-- Recursively list all files in a directory
function _M.list_files(dir, pattern)
  local files = {}
  pattern = pattern or ".*"

  local function scan_dir(path, prefix)
    prefix = prefix or ""
    for file in lfs.dir(path) do
      if file ~= "." and file ~= ".." then
        local filepath = path .. "/" .. file
        local relpath = prefix .. "/" .. file
        local attr = lfs.attributes(filepath)

        if attr and attr.mode == "directory" then
          scan_dir(filepath, relpath)
        elseif attr and attr.mode == "file" and file:match(pattern) then
          table.insert(files, {
            path = filepath,
            relative_path = relpath:sub(2),  -- Remove leading slash
            size = attr.size,
            modification_time = attr.modification
          })
        end
      end
    end
  end

  local ok, err = pcall(scan_dir, dir)
  if not ok then
    return nil, "Failed to scan directory: " .. tostring(err)
  end

  return files
end

-- Get all Capsium packages in a directory
function _M.get_packages(dir)
  local packages = {}
  local files, err = _M.list_files(dir, "%.cap$")

  if not files then
    return nil, err
  end

  for _, file in ipairs(files) do
    local package_name = file.relative_path:match("([^/]+)%.cap$")
    if package_name then
      table.insert(packages, {
        name = package_name,
        path = file.path,
        size = file.size,
        modification_time = file.modification_time
      })
    end
  end

  return packages
end

-- Format timestamp to ISO 8601
function _M.format_timestamp(timestamp)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", timestamp)
end

-- Deep copy a table
function _M.deep_copy(orig)
  local orig_type = type(orig)
  local copy
  if orig_type == 'table' then
    copy = {}
    for orig_key, orig_value in next, orig, nil do
      copy[_M.deep_copy(orig_key)] = _M.deep_copy(orig_value)
    end
    setmetatable(copy, _M.deep_copy(getmetatable(orig)))
  else
    copy = orig
  end
  return copy
end

-- Merge two tables
function _M.merge_tables(t1, t2)
  local result = _M.deep_copy(t1)
  for k, v in pairs(t2) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = _M.merge_tables(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

-- URL encode a string
function _M.url_encode(str)
  if str then
    str = string.gsub(str, "\n", "\r\n")
    str = string.gsub(str, "([^%w %-%_%.%~])",
      function(c) return string.format("%%%02X", string.byte(c)) end)
    str = string.gsub(str, " ", "+")
  end
  return str
end

-- URL decode a string
function _M.url_decode(str)
  if str then
    str = string.gsub(str, "+", " ")
    str = string.gsub(str, "%%(%x%x)",
      function(h) return string.char(tonumber(h, 16)) end)
  end
  return str
end

-- Read JSON file
function _M.read_json_file(path)
  local cjson = require "cjson"
  local file, err = io.open(path, "r")
  if not file then
    return nil, "Failed to open file: " .. tostring(err)
  end

  local content = file:read("*all")
  file:close()

  local ok, result = pcall(cjson.decode, content)
  if not ok then
    return nil, "Failed to parse JSON: " .. tostring(result)
  end

  return result
end

-- Write JSON file
function _M.write_json_file(path, data)
  local cjson = require "cjson"
  local ok, json_str = pcall(cjson.encode, data)
  if not ok then
    return nil, "Failed to encode JSON: " .. tostring(json_str)
  end

  local file, err = io.open(path, "w")
  if not file then
    return nil, "Failed to open file for writing: " .. tostring(err)
  end

  file:write(json_str)
  file:close()

  return true
end

-- ---------------------------------------------------------------------------
-- Base64 (pure Lua; ngx.base64 only exists inside nginx workers)
-- ---------------------------------------------------------------------------

local B64_ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local b64_dec = {} -- byte value of alphabet char -> sextet
local b64_enc = {} -- sextet -> alphabet char
for i = 1, #B64_ALPHABET do
  b64_dec[B64_ALPHABET:byte(i)] = i - 1
  b64_enc[i - 1] = B64_ALPHABET:sub(i, i)
end

-- Decode base64 (standard alphabet, "=" padding tolerated, whitespace
-- ignored). Grouped arithmetic only — no running accumulator, so binary
-- payloads of any size decode exactly.
-- Returns decoded string | nil, err.
function _M.base64_decode(data)
  if type(data) ~= "string" then
    return nil, "invalid base64"
  end

  data = data:gsub("%s", "")
  if data:sub(-2) == "==" or data:sub(-1) == "=" then
    data = data:gsub("=+$", "")
  end
  if #data % 4 == 1 then
    return nil, "invalid base64 length"
  end

  local out = {}
  for i = 1, #data, 4 do
    local b1, b2, b3, b4 = data:byte(i, i + 3)
    local s1, s2 = b64_dec[b1], b64_dec[b2]
    if not s1 or not s2 then
      return nil, "invalid base64"
    end
    local s3 = b3 and b64_dec[b3] or 0
    local s4 = b4 and b64_dec[b4] or 0
    if (b3 and not s3) or (b4 and not s4) then
      return nil, "invalid base64"
    end

    local n = ((s1 * 64 + s2) * 64 + s3) * 64 + s4
    out[#out + 1] = string.char(math.floor(n / 65536) % 256)
    if b3 then
      out[#out + 1] = string.char(math.floor(n / 256) % 256)
    end
    if b4 then
      out[#out + 1] = string.char(n % 256)
    end
  end

  return table.concat(out)
end

-- Encode base64 (standard alphabet with "=" padding).
function _M.base64_encode(data)
  local out = {}
  for i = 1, #data, 3 do
    local a, b, c = data:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    out[#out + 1] = b64_enc[math.floor(n / 262144)]
    out[#out + 1] = b64_enc[math.floor(n / 4096) % 64]
    out[#out + 1] = b and b64_enc[math.floor(n / 64) % 64] or "="
    out[#out + 1] = c and b64_enc[n % 64] or "="
  end
  return table.concat(out)
end

-- Check if file exists
function _M.file_exists(path)
  local attr = lfs.attributes(path)
  return attr ~= nil and attr.mode == "file"
end

-- Check if directory exists
function _M.dir_exists(path)
  local attr = lfs.attributes(path)
  return attr ~= nil and attr.mode == "directory"
end

-- Create directory recursively
function _M.mkdir_p(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, part)
  end

  local current_path = ""
  for i, part in ipairs(parts) do
    if i == 1 and path:sub(1, 1) == "/" then
      current_path = "/" .. part
    else
      current_path = current_path .. "/" .. part
    end

    if not _M.dir_exists(current_path) then
      local ok, err = lfs.mkdir(current_path)
      if not ok then
        return nil, "Failed to create directory: " .. tostring(err)
      end
    end
  end

  return true
end

return _M
