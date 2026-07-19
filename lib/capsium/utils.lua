-- Capsium Lua Library
-- Utility functions (framework-agnostic)

local _M = {
  _VERSION = "0.2.0"
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
