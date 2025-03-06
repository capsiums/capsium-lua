-- capsium-nginx configuration module
-- Handles loading and managing configuration for Capsium Nginx Reactor

local _M = {}

local cjson = require "cjson"
local lfs = require "lfs"

-- Default configuration paths
local DEFAULT_CONFIG_PATHS = {
    "/etc/capsium/config.json",
    "/etc/capsium/nginx/config.json",
    "/var/lib/capsium/config.json",
    "./config.json"
}

-- Default configuration values
local DEFAULT_CONFIG = {
    package_dir = "/var/lib/capsium/packages",
    extract_dir = "/var/lib/capsium/extracted",
    cache_enabled = true,
    cache_ttl = 3600,  -- 1 hour
    log_level = "info",
    packages_config_dir = "/etc/capsium/packages",
    mounts = {}
}

-- Load JSON file
local function load_json_file(file_path)
    local f, err = io.open(file_path, "r")
    if not f then
        return nil, "Failed to open file: " .. (err or "unknown error")
    end

    local content = f:read("*a")
    f:close()

    local ok, data = pcall(cjson.decode, content)
    if not ok then
        return nil, "Failed to parse JSON: " .. (data or "unknown error")
    end

    return data
end

-- Save JSON file
local function save_json_file(file_path, data)
    local f, err = io.open(file_path, "w")
    if not f then
        return nil, "Failed to open file for writing: " .. (err or "unknown error")
    end

    local ok, json = pcall(cjson.encode, data)
    if not ok then
        f:close()
        return nil, "Failed to encode JSON: " .. (json or "unknown error")
    end

    f:write(json)
    f:close()

    return true
end

-- Check if file exists
local function file_exists(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "file"
end

-- Check if directory exists
local function dir_exists(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "directory"
end

-- Create directory if it doesn't exist
local function ensure_dir(path)
    if not dir_exists(path) then
        local success = lfs.mkdir(path)
        if not success then
            return false, "Failed to create directory: " .. path
        end
    end
    return true
end

-- Find the first existing config file from a list of paths
local function find_config_file(paths)
    for _, path in ipairs(paths) do
        if file_exists(path) then
            return path
        end
    end
    return nil
end

-- Load package-specific configuration
local function load_package_config(package_name, config_dir)
    if not config_dir or not dir_exists(config_dir) then
        return nil
    end

    local config_path = config_dir .. "/" .. package_name .. ".json"
    if not file_exists(config_path) then
        return nil
    end

    return load_json_file(config_path)
end

-- Load all package configurations from a directory
local function load_package_configs(config_dir)
    local configs = {}

    if not config_dir or not dir_exists(config_dir) then
        return configs
    end

    for file in lfs.dir(config_dir) do
        if file:match("%.json$") then
            local package_name = file:gsub("%.json$", "")
            local config, err = load_json_file(config_dir .. "/" .. file)
            if config then
                configs[package_name] = config
            end
        end
    end

    return configs
end

-- Extract configuration from a Capsium package
local function extract_package_config(package_path, extract_path)
    -- This would extract the capsium-config.json from the package
    -- For now, we'll just return nil as this requires the extractor module
    return nil
end

-- Initialize configuration
function _M.init(options)
    options = options or {}

    -- Determine config file path
    local config_path = options.config_path
    if not config_path then
        -- Check environment variable
        config_path = os.getenv("CAPSIUM_CONFIG_PATH")
    end

    -- If still not set, try default paths
    if not config_path then
        config_path = find_config_file(DEFAULT_CONFIG_PATHS)
    end

    -- Load configuration
    local config = {}
    if config_path and file_exists(config_path) then
        local loaded_config, err = load_json_file(config_path)
        if loaded_config then
            config = loaded_config
        else
            ngx.log(ngx.WARN, "Failed to load config from ", config_path, ": ", err)
        end
    end

    -- Merge with defaults
    for k, v in pairs(DEFAULT_CONFIG) do
        if config[k] == nil then
            config[k] = v
        end
    end

    -- Load package-specific configurations
    if config.packages_config_dir and dir_exists(config.packages_config_dir) then
        local package_configs = load_package_configs(config.packages_config_dir)
        config.package_configs = package_configs
    else
        config.package_configs = {}
    end

    -- Store the config
    _M.config = config

    return config
end

-- Get configuration
function _M.get_config()
    return _M.config or DEFAULT_CONFIG
end

-- Get package configuration
function _M.get_package_config(package_name)
    local config = _M.get_config()

    -- Check if there's a specific configuration for this package
    if config.package_configs and config.package_configs[package_name] then
        return config.package_configs[package_name]
    end

    -- Check if there's a mount configuration for this package
    for _, mount in ipairs(config.mounts or {}) do
        if mount.package == package_name then
            return mount
        end
    end

    -- Return default configuration
    return {
        path = "/capsium/" .. package_name,
        domain = nil,
        port = nil
    }
end

-- Get mount configuration for a package
function _M.get_mount_config(package_name)
    local pkg_config = _M.get_package_config(package_name)

    -- Ensure the mount has at least the basic properties
    pkg_config.path = pkg_config.path or "/capsium/" .. package_name
    pkg_config.domain = pkg_config.domain or nil
    pkg_config.port = pkg_config.port or nil

    return pkg_config
end

-- Save configuration
function _M.save_config(config_path)
    config_path = config_path or (_M.config and _M.config.config_path)
    if not config_path then
        return nil, "No configuration path specified"
    end

    -- Ensure the directory exists
    local dir_path = config_path:match("(.+)/[^/]+$")
    if dir_path then
        local ok, err = ensure_dir(dir_path)
        if not ok then
            return nil, err
        end
    end

    -- Save the configuration
    return save_json_file(config_path, _M.config)
end

return _M
