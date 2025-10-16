-- capsium-lua Lua module
-- Package extraction functionality

local _M = {
    _VERSION = "0.1.0"
}

local cjson = require "cjson"
local lfs = require "lfs"
local zip = require "brimworks.zip"

-- Module configuration
local config = {}

-- Initialize the module with configuration
function _M.init(cfg)
    config = cfg
end

-- Ensure directories exist (creates parent directories recursively)
function _M.ensure_dirs(...)
    local dirs = {...}
    for _, dir in ipairs(dirs) do
        local stat = lfs.attributes(dir)
        if not stat then
            -- Directory doesn't exist, create it and all parent directories
            local path = ""
            for part in dir:gmatch("[^/]+") do
                path = path .. "/" .. part
                local parent_stat = lfs.attributes(path)
                if not parent_stat then
                    local success, err = lfs.mkdir(path)
                    if not success then
                        return false, "Failed to create directory " .. path .. ": " .. (err or "unknown error")
                    end
                elseif parent_stat.mode ~= "directory" then
                    return false, path .. " exists but is not a directory"
                end
            end
        elseif stat.mode ~= "directory" then
            return false, dir .. " exists but is not a directory"
        end
    end
    return true
end

-- Get package info from metadata.json
function _M.get_package_info(extract_path)
    local metadata_path = extract_path .. "/metadata.json"
    local f, err = io.open(metadata_path, "r")
    if not f then
        return nil, "Failed to open metadata.json: " .. (err or "unknown error")
    end

    local content = f:read("*all")
    f:close()

    local ok, metadata = pcall(cjson.decode, content)
    if not ok then
        return nil, "Failed to parse metadata.json: " .. metadata
    end

    return metadata
end

-- Check if package is already extracted and up to date
function _M.is_extracted(package_path, extract_dir)
    local package_stat = lfs.attributes(package_path)
    if not package_stat then
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
    local metadata_stat = lfs.attributes(metadata_path)
    if not metadata_stat then
        return false, "Package not extracted"
    end

    -- Check if package file is newer than extracted metadata
    if package_stat.modification > metadata_stat.modification then
        return false, "Package file is newer than extracted files"
    end

    return true, extract_path
end

-- Extract a Capsium package
function _M.extract_package(package_path, extract_dir)
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
    local ok, err = _M.ensure_dirs(extract_path)
    if not ok then
        return nil, err
    end

    -- Open the zip file
    local zfile, err = zip.open(package_path)
    if not zfile then
        return nil, "Failed to open package as zip: " .. (err or "unknown error")
    end

    -- Get number of files in archive
    local num_files = zfile:get_num_files()
    if not num_files then
        zfile:close()
        return nil, "Failed to get number of files in package"
    end

    -- Extract all files (Lua uses 1-based indexing)
    for i = 1, num_files do
        local filename = zfile:get_name(i)
        if not filename then
            zfile:close()
            return nil, "Failed to get filename for index " .. i
        end

        local file_stat = zfile:stat(filename)
        if not file_stat then
            zfile:close()
            return nil, "Failed to get file info for " .. filename
        end

        -- Skip directories (they end with /)
        if not filename:match("/$") then
            -- Create directories as needed
            local dir = filename:match("(.*)/")
            if dir and dir ~= "" then
                local full_dir = extract_path .. "/" .. dir
                local ok, err = _M.ensure_dirs(full_dir)
                if not ok then
                    zfile:close()
                    return nil, err
                end
            end

            -- Extract the file
            local file_handle, err = zfile:open(filename)
            if not file_handle then
                zfile:close()
                return nil, "Failed to open file in zip: " .. filename .. ": " .. (err or "unknown error")
            end

            -- Read the file content (use file size from stat)
            local file_content = file_handle:read(file_stat.size)
            file_handle:close()

            -- Write the file
            local out_path = extract_path .. "/" .. filename
            local out_file, err = io.open(out_path, "wb")
            if not out_file then
                zfile:close()
                return nil, "Failed to create file " .. out_path .. ": " .. (err or "unknown error")
            end

            out_file:write(file_content)
            out_file:close()
        end
    end

    zfile:close()

    -- Verify metadata.json exists
    local metadata_path = extract_path .. "/metadata.json"
    if not lfs.attributes(metadata_path) then
        return nil, "Extracted package does not contain metadata.json"
    end

    return extract_path
end

return _M
