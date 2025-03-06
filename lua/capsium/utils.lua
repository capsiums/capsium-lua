-- capsium-nginx Lua module
-- Utility functions

local _M = {
    _VERSION = "0.1.0"
}

local cjson = require "cjson"
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

                if attr.mode == "directory" then
                    scan_dir(filepath, relpath)
                elseif attr.mode == "file" and file:match(pattern) then
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

    scan_dir(dir)
    return files
end

-- Get all Capsium packages in a directory
function _M.get_packages(dir)
    local packages = {}
    local files = _M.list_files(dir, "%.cap$")

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

-- Calculate SHA-256 hash of a file
function _M.calculate_hash(file_path)
    local f, err = io.open(file_path, "rb")
    if not f then
        return nil, "Failed to open file: " .. (err or "unknown error")
    end

    local content = f:read("*all")
    f:close()

    -- Use ngx.sha1_bin for hashing if available
    if ngx and ngx.sha1_bin then
        local binary_hash = ngx.sha1_bin(content)
        return ngx.encode_base64(binary_hash):gsub("+", "-"):gsub("/", "_"):gsub("=", "")
    else
        -- Fallback to a simple hash function if ngx.sha1_bin is not available
        local hash = 0
        for i = 1, #content do
            hash = (hash * 31 + string.byte(content, i)) % 2^32
        end
        return string.format("%08x", hash)
    end
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

return _M
