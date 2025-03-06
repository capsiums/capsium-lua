-- capsium-nginx Lua module
-- Main entry point for the Capsium Nginx plugin

local _M = {
    _VERSION = "0.1.0"
}

local cjson = require "cjson"
local extractor = require "capsium.extractor"
local router = require "capsium.router"
local utils = require "capsium.utils"

-- Configuration defaults
local default_config = {
    package_dir = "/var/lib/capsium/packages",
    extract_dir = "/var/lib/capsium/extracted",
    cache_enabled = true,
    cache_ttl = 3600,  -- 1 hour
    log_level = "info"
}

-- Initialize the module with configuration
function _M.init(config)
    local cfg = config or {}

    -- Merge with defaults
    for k, v in pairs(default_config) do
        if cfg[k] == nil then
            cfg[k] = v
        end
    end

    -- Ensure directories exist
    local ok, err = extractor.ensure_dirs(cfg.package_dir, cfg.extract_dir)
    if not ok then
        ngx.log(ngx.ERR, "Failed to create Capsium directories: ", err)
        return false, err
    end

    -- Store config in module
    _M.config = cfg

    -- Initialize submodules
    extractor.init(cfg)
    router.init(cfg)

    ngx.log(ngx.INFO, "Capsium Nginx plugin initialized")
    return true
end

-- Handle incoming request
function _M.handle_request()
    -- Get the package name from the request
    local package_name = ngx.var.capsium_package
    if not package_name then
        ngx.log(ngx.ERR, "No Capsium package specified")
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    -- Check if package exists and extract if needed
    local package_path = _M.config.package_dir .. "/" .. package_name
    local extract_path, err = extractor.extract_package(package_path, _M.config.extract_dir)
    if not extract_path then
        ngx.log(ngx.ERR, "Failed to extract Capsium package: ", err)
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Load routes from the extracted package
    local routes, err = router.load_routes(extract_path)
    if not routes then
        ngx.log(ngx.ERR, "Failed to load routes from package: ", err)
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- Resolve the request path to a file
    local request_path = ngx.var.uri
    local file_path, mime_type = router.resolve_route(routes, request_path, extract_path)
    if not file_path then
        ngx.log(ngx.WARN, "Route not found for path: ", request_path)
        return ngx.exit(ngx.HTTP_NOT_FOUND)
    end

    -- Serve the file
    ngx.header.content_type = mime_type or "application/octet-stream"

    -- Use nginx's internal mechanisms to serve the file
    ngx.var.capsium_file_path = file_path
    return ngx.exec("@capsium_serve_file")
end

-- Get metadata for all packages
function _M.get_metadata()
    local packages = utils.get_packages(_M.config.package_dir)
    local metadata_list = {}

    for _, package in ipairs(packages) do
        local extract_path = _M.config.extract_dir .. "/" .. package.name
        local metadata, err = extractor.get_package_info(extract_path)

        if metadata then
            table.insert(metadata_list, {
                name = metadata.name,
                version = metadata.version,
                dependencies = metadata.dependencies,
                timestamp = utils.format_timestamp(package.modification_time)
            })
        end
    end

    return { packages = metadata_list }
end

-- Get routes for all packages
function _M.get_routes()
    local packages = utils.get_packages(_M.config.package_dir)
    local routes_list = {}

    for _, package in ipairs(packages) do
        local extract_path = _M.config.extract_dir .. "/" .. package.name
        local routes, err = router.load_routes(extract_path)

        if routes then
            local package_routes = {}
            for path, route in pairs(routes.routes) do
                table.insert(package_routes, {
                    path = path,
                    target = route.target.file
                })
            end

            table.insert(routes_list, {
                package = package.name,
                routes = package_routes
            })
        end
    end

    return { routes = routes_list }
end

-- Get content hashes for all packages
function _M.get_content_hashes()
    local packages = utils.get_packages(_M.config.package_dir)
    local hashes_list = {}

    for _, package in ipairs(packages) do
        local hash, err = utils.calculate_hash(package.path)

        if hash then
            table.insert(hashes_list, {
                package = package.name,
                hash = hash
            })
        end
    end

    return { contentHashes = hashes_list }
end

-- Get content validity for all packages
function _M.get_content_validity()
    local packages = utils.get_packages(_M.config.package_dir)
    local validity_list = {}

    for _, package in ipairs(packages) do
        local extract_path = _M.config.extract_dir .. "/" .. package.name
        local metadata_path = extract_path .. "/metadata.json"

        -- Check if metadata.json exists
        local valid = false
        local reason = nil

        if lfs.attributes(metadata_path) then
            valid = true
        else
            reason = "Missing metadata.json"
        end

        table.insert(validity_list, {
            package = package.name,
            valid = valid,
            lastChecked = utils.format_timestamp(os.time()),
            reason = reason
        })
    end

    return { contentValidity = validity_list }
end

return _M
