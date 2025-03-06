-- capsium-nginx Lua module
-- Route resolution functionality

local _M = {
    _VERSION = "0.1.0"
}

local cjson = require "cjson"
local lfs = require "lfs"

-- Module configuration
local config = {}

-- MIME type mapping
local mime_types = {
    [".html"] = "text/html",
    [".htm"] = "text/html",
    [".css"] = "text/css",
    [".js"] = "application/javascript",
    [".json"] = "application/json",
    [".xml"] = "application/xml",
    [".txt"] = "text/plain",
    [".jpg"] = "image/jpeg",
    [".jpeg"] = "image/jpeg",
    [".png"] = "image/png",
    [".gif"] = "image/gif",
    [".svg"] = "image/svg+xml",
    [".pdf"] = "application/pdf",
    [".zip"] = "application/zip",
    [".ico"] = "image/x-icon",
    [".woff"] = "font/woff",
    [".woff2"] = "font/woff2",
    [".ttf"] = "font/ttf",
    [".eot"] = "application/vnd.ms-fontobject",
    [".otf"] = "font/otf",
    [".mp4"] = "video/mp4",
    [".webm"] = "video/webm",
    [".mp3"] = "audio/mpeg",
    [".wav"] = "audio/wav"
}

-- Initialize the module with configuration
function _M.init(cfg)
    config = cfg
end

-- Get MIME type for a file
function _M.get_mime_type(file_path)
    local ext = file_path:match("%.([^%.]+)$")
    if ext then
        ext = "." .. ext:lower()
        return mime_types[ext]
    end
    return nil
end

-- Load routes from a Capsium package
function _M.load_routes(extract_path)
    local routes_path = extract_path .. "/routes.json"
    local routes_stat = lfs.attributes(routes_path)

    if not routes_stat then
        -- If routes.json doesn't exist, generate default routes
        return _M.generate_default_routes(extract_path)
    end

    -- Read routes.json
    local f, err = io.open(routes_path, "r")
    if not f then
        return nil, "Failed to open routes.json: " .. (err or "unknown error")
    end

    local content = f:read("*all")
    f:close()

    local ok, routes = pcall(cjson.decode, content)
    if not ok then
        return nil, "Failed to parse routes.json: " .. routes
    end

    -- Validate routes
    if not routes.routes or type(routes.routes) ~= "table" then
        return nil, "Invalid routes.json: missing or invalid 'routes' property"
    end

    return routes
end

-- Generate default routes for a Capsium package
function _M.generate_default_routes(extract_path)
    local content_path = extract_path .. "/content"
    local content_stat = lfs.attributes(content_path)

    if not content_stat or content_stat.mode ~= "directory" then
        return nil, "Package does not contain a content directory"
    end

    local routes = {
        routes = {}
    }

    -- Add default route for index.html
    local index_path = content_path .. "/index.html"
    if lfs.attributes(index_path) then
        routes.routes["/"] = {
            path = "/",
            target = {
                file = "content/index.html"
            }
        }
    end

    -- Recursively scan content directory and add routes
    local function scan_dir(dir, prefix)
        prefix = prefix or ""
        for file in lfs.dir(dir) do
            if file ~= "." and file ~= ".." then
                local path = dir .. "/" .. file
                local stat = lfs.attributes(path)

                if stat.mode == "directory" then
                    -- Recursively scan subdirectory
                    scan_dir(path, prefix .. "/" .. file)
                else
                    -- Add route for file
                    local route_path = prefix .. "/" .. file
                    local target_path = "content" .. route_path

                    routes.routes[route_path] = {
                        path = route_path,
                        target = {
                            file = target_path
                        }
                    }
                end
            end
        end
    end

    scan_dir(content_path)

    return routes
end

-- Resolve a route to a file path
function _M.resolve_route(routes, request_path, extract_path)
    -- Check for exact route match
    local route = routes.routes[request_path]

    -- If no exact match, try with trailing slash
    if not route and request_path:sub(-1) ~= "/" then
        route = routes.routes[request_path .. "/"]
    end

    -- If still no match, try without trailing slash
    if not route and request_path:sub(-1) == "/" then
        route = routes.routes[request_path:sub(1, -2)]
    end

    -- If still no match, try with /index.html
    if not route and request_path:sub(-1) == "/" then
        route = routes.routes[request_path .. "index.html"]
    elseif not route then
        route = routes.routes[request_path .. "/index.html"]
    end

    -- If no route found, return nil
    if not route then
        return nil
    end

    -- Get target file path
    local target_file = route.target.file
    if not target_file then
        return nil
    end

    -- Construct full file path
    local file_path = extract_path .. "/" .. target_file

    -- Check if file exists
    if not lfs.attributes(file_path) then
        return nil
    end

    -- Get MIME type
    local mime_type = _M.get_mime_type(file_path)

    return file_path, mime_type
end

return _M
