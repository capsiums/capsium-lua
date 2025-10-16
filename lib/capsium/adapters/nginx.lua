-- capsium-lua Nginx Adapter
-- OpenResty/Nginx-specific implementations for fs and zip operations

local lfs = require "lfs"
local zip = require "brimworks.zip"

local _M = {
  _VERSION = "0.1.0"
}

-- File System Adapter for OpenResty/Nginx
_M.fs_adapter = {}

-- Check if file exists
function _M.fs_adapter.file_exists(path)
  local attr = lfs.attributes(path)
  return attr ~= nil and attr.mode == "file"
end

-- Check if directory exists
function _M.fs_adapter.dir_exists(path)
  local attr = lfs.attributes(path)
  return attr ~= nil and attr.mode == "directory"
end

-- Get file modification time
function _M.fs_adapter.get_mtime(path)
  local attr = lfs.attributes(path)
  return attr and attr.modification
end

-- Create directory recursively
function _M.fs_adapter.mkdir_p(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, part)
  end

  local current = ""
  for _, part in ipairs(parts) do
    current = current .. "/" .. part
    local attr = lfs.attributes(current)

    if not attr then
      local success, err = lfs.mkdir(current)
      if not success then
        return false, "Failed to create directory " .. current .. ": " ..
                      (err or "unknown error")
      end
    elseif attr.mode ~= "directory" then
      return false, current .. " exists but is not a directory"
    end
  end

  return true
end

-- List directory contents
function _M.fs_adapter.list_dir(path)
  local entries = {}
  for entry in lfs.dir(path) do
    table.insert(entries, entry)
  end
  return entries
end

-- Write file
function _M.fs_adapter.write_file(path, content, mode)
  mode = mode or "w"
  local f, err = io.open(path, mode)
  if not f then
    return false, err
  end

  f:write(content)
  f:close()
  return true
end

-- Read file
function _M.fs_adapter.read_file(path, mode)
  mode = mode or "r"
  local f, err = io.open(path, mode)
  if not f then
    return nil, err
  end

  local content = f:read("*all")
  f:close()
  return content
end

-- ZIP Adapter for OpenResty/Nginx
_M.zip_adapter = {}

-- Open ZIP file
function _M.zip_adapter.open(path)
  return zip.open(path)
end

-- Close ZIP file
function _M.zip_adapter.close(zfile)
  if zfile then
    zfile:close()
  end
end

-- List files in ZIP archive
function _M.zip_adapter.list_files(zfile)
  local files = {}
  local num_files = zfile:get_num_files()

  if not num_files then
    return nil, "Failed to get number of files in archive"
  end

  -- Lua uses 1-based indexing
  for i = 1, num_files do
    local filename = zfile:get_name(i)
    if filename then
      table.insert(files, filename)
    end
  end

  return files
end

-- Read file from ZIP archive
function _M.zip_adapter.read_file(zfile, filename)
  -- Get file stats
  local file_stat = zfile:stat(filename)
  if not file_stat then
    return nil, "Failed to get file info for " .. filename
  end

  -- Open file in ZIP
  local file_handle, err = zfile:open(filename)
  if not file_handle then
    return nil, "Failed to open file in zip: " .. (err or "unknown error")
  end

  -- Read file content
  local content = file_handle:read(file_stat.size)
  file_handle:close()

  return content
end

return _M
