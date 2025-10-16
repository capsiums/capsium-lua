-- capsium-lua Package Extractor Module
-- Framework-agnostic package extraction functionality

local utils = require "capsium.utils"

local _M = {
  _VERSION = "0.1.0"
}

-- Default configuration
local config = {
  fs_adapter = nil,  -- File system operations adapter
  zip_adapter = nil, -- ZIP operations adapter
}

-- Initialize the module with configuration and adapters
function _M.init(cfg)
  config = utils.merge_tables(config, cfg or {})

  -- Validate required adapters
  if not config.fs_adapter then
    error("fs_adapter is required for extractor module")
  end
  if not config.zip_adapter then
    error("zip_adapter is required for extractor module")
  end

  return true
end

-- Get package info from metadata.json
function _M.get_package_info(extract_path)
  local metadata_path = extract_path .. "/metadata.json"
  local metadata, err = utils.read_json_file(metadata_path)

  if not metadata then
    return nil, "Failed to read metadata.json: " .. (err or "unknown error")
  end

  return metadata
end

-- Check if package is already extracted and up to date
function _M.is_extracted(package_path, extract_dir)
  local fs = config.fs_adapter

  -- Check if package file exists
  if not fs.file_exists(package_path) then
    return false, "Package file does not exist"
  end

  -- Generate extract path based on package name
  local package_name = package_path:match("([^/]+)%.cap$")
  if not package_name then
    return false, "Invalid package filename (must end with .cap)"
  end

  local extract_path = extract_dir .. "/" .. package_name
  local metadata_path = extract_path .. "/metadata.json"

  -- Check if metadata.json exists in extract path
  if not fs.file_exists(metadata_path) then
    return false, "Package not extracted"
  end

  -- Get modification times
  local package_mtime = fs.get_mtime(package_path)
  local metadata_mtime = fs.get_mtime(metadata_path)

  if not package_mtime or not metadata_mtime then
    return false, "Failed to get modification times"
  end

  -- Check if package file is newer than extracted metadata
  if package_mtime > metadata_mtime then
    return false, "Package file is newer than extracted files"
  end

  return true, extract_path
end

-- Extract a Capsium package
function _M.extract_package(package_path, extract_dir)
  local fs = config.fs_adapter
  local zip = config.zip_adapter

  -- Check if package is already extracted
  local is_extracted, result = _M.is_extracted(package_path, extract_dir)
  if is_extracted then
    return result
  end

  -- Package needs to be extracted
  local package_name = package_path:match("([^/]+)%.cap$")
  if not package_name then
    return nil, "Invalid package filename (must end with .cap)"
  end

  local extract_path = extract_dir .. "/" .. package_name

  -- Create extract directory if it doesn't exist
  local ok, err = fs.mkdir_p(extract_path)
  if not ok then
    return nil, "Failed to create extract directory: " .. (err or "unknown")
  end

  -- Open the zip file
  local zfile, err = zip.open(package_path)
  if not zfile then
    return nil, "Failed to open package as zip: " .. (err or "unknown error")
  end

  -- Get list of files in archive
  local files, err = zip.list_files(zfile)
  if not files then
    zip.close(zfile)
    return nil, "Failed to list files in package: " .. (err or "unknown")
  end

  -- Extract all files
  for _, filename in ipairs(files) do
    -- Skip directories (they end with /)
    if not filename:match("/$") then
      -- Create directories as needed
      local dir = filename:match("(.*)/")
      if dir and dir ~= "" then
        local full_dir = extract_path .. "/" .. dir
        local ok, err = fs.mkdir_p(full_dir)
        if not ok then
          zip.close(zfile)
          return nil, "Failed to create directory " .. full_dir .. ": " ..
                      (err or "unknown")
        end
      end

      -- Extract the file
      local content, err = zip.read_file(zfile, filename)
      if not content then
        zip.close(zfile)
        return nil, "Failed to read file from zip: " .. filename .. ": " ..
                    (err or "unknown error")
      end

      -- Write the file
      local out_path = extract_path .. "/" .. filename
      local ok, err = fs.write_file(out_path, content, "wb")
      if not ok then
        zip.close(zfile)
        return nil, "Failed to write file " .. out_path .. ": " ..
                    (err or "unknown error")
      end
    end
  end

  zip.close(zfile)

  -- Verify metadata.json exists
  local metadata_path = extract_path .. "/metadata.json"
  if not fs.file_exists(metadata_path) then
    return nil, "Extracted package does not contain metadata.json"
  end

  return extract_path
end

return _M
