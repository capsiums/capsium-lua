-- capsium-lua Package Module
-- Framework-agnostic Capsium package representation

local utils = require "capsium.utils"

local _M = {
  _VERSION = "0.1.0"
}
local _M_mt = { __index = _M }

-- MIME type mapping
local MIME_TYPES = {
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

-- Create a new Package instance
function _M.new(extract_path, fs_adapter)
  if not extract_path then
    return nil, "extract_path is required"
  end

  if not fs_adapter then
    return nil, "fs_adapter is required"
  end

  local self = {
    extract_path = extract_path,
    fs_adapter = fs_adapter,
    metadata = nil,
    routes = nil,
    manifest = nil,
    _loaded = false
  }

  return setmetatable(self, _M_mt)
end

-- Load package data (metadata, routes, manifest)
function _M:load()
  if self._loaded then
    return true
  end

  -- Load metadata
  local metadata, err = self:load_metadata()
  if not metadata then
    return nil, "Failed to load metadata: " .. (err or "unknown")
  end
  self.metadata = metadata

  -- Load routes (generate defaults if routes.json doesn't exist)
  local routes, err = self:load_routes()
  if not routes then
    return nil, "Failed to load routes: " .. (err or "unknown")
  end
  self.routes = routes

  -- Load manifest (optional)
  local manifest, err = self:load_manifest()
  if manifest then
    self.manifest = manifest
  end

  self._loaded = true
  return true
end

-- Load metadata.json
function _M:load_metadata()
  local metadata_path = self.extract_path .. "/metadata.json"
  local metadata, err = utils.read_json_file(metadata_path)

  if not metadata then
    return nil, "Failed to read metadata.json: " .. (err or "unknown")
  end

  return metadata
end

-- Load routes.json or generate default routes
function _M:load_routes()
  local routes_path = self.extract_path .. "/routes.json"

  if self.fs_adapter.file_exists(routes_path) then
    -- Load routes from routes.json
    local routes, err = utils.read_json_file(routes_path)
    if not routes then
      return nil, "Failed to read routes.json: " .. (err or "unknown")
    end

    -- Validate routes
    if not routes.routes or type(routes.routes) ~= "table" then
      return nil, "Invalid routes.json: missing or invalid 'routes' property"
    end

    return routes
  else
    -- Generate default routes
    return self:generate_default_routes()
  end
end

-- Load manifest.json (optional)
function _M:load_manifest()
  local manifest_path = self.extract_path .. "/manifest.json"

  if not self.fs_adapter.file_exists(manifest_path) then
    return nil, "manifest.json not found"
  end

  local manifest, err = utils.read_json_file(manifest_path)
  if not manifest then
    return nil, "Failed to read manifest.json: " .. (err or "unknown")
  end

  return manifest
end

-- Generate default routes for the package
function _M:generate_default_routes()
  local content_path = self.extract_path .. "/content"

  if not self.fs_adapter.dir_exists(content_path) then
    return nil, "Package does not contain a content directory"
  end

  local routes = {
    routes = {}
  }

  -- Add default route for index.html
  local index_path = content_path .. "/index.html"
  if self.fs_adapter.file_exists(index_path) then
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
    local entries = self.fs_adapter.list_dir(dir)
    if not entries then
      return
    end

    for _, entry in ipairs(entries) do
      if entry ~= "." and entry ~= ".." then
        local path = dir .. "/" .. entry

        if self.fs_adapter.dir_exists(path) then
          -- Recursively scan subdirectory
          scan_dir(path, prefix .. "/" .. entry)
        elseif self.fs_adapter.file_exists(path) then
          -- Add route for file
          local route_path = prefix .. "/" .. entry
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

-- Get MIME type for a file based on extension
function _M.get_mime_type(file_path)
  local ext = file_path:match("%.([^%.]+)$")
  if ext then
    ext = "." .. ext:lower()
    return MIME_TYPES[ext]
  end
  return nil
end

-- Resolve a route to a file path
function _M:resolve_route(request_path)
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end

  local route = nil

  -- Convert array-based routes to indexed routes for faster lookup
  if self.routes.routes and #self.routes.routes > 0 and
     self.routes.routes[1].path then
    -- Routes are in array format, need to find matching route
    for _, r in ipairs(self.routes.routes) do
      if r.path == request_path then
        route = r
        break
      end
    end

    -- If no exact match, try with trailing slash
    if not route and request_path:sub(-1) ~= "/" then
      for _, r in ipairs(self.routes.routes) do
        if r.path == request_path .. "/" then
          route = r
          break
        end
      end
    end

    -- If still no match, try without trailing slash
    if not route and request_path:sub(-1) == "/" then
      local path_without_slash = request_path:sub(1, -2)
      for _, r in ipairs(self.routes.routes) do
        if r.path == path_without_slash then
          route = r
          break
        end
      end
    end
  else
    -- Routes are in indexed format (legacy/generated routes)
    route = self.routes.routes[request_path]

    -- If no exact match, try with trailing slash
    if not route and request_path:sub(-1) ~= "/" then
      route = self.routes.routes[request_path .. "/"]
    end

    -- If still no match, try without trailing slash
    if not route and request_path:sub(-1) == "/" then
      route = self.routes.routes[request_path:sub(1, -2)]
    end
  end

  -- If no route found, return nil
  if not route then
    return nil, "Route not found: " .. request_path
  end

  -- Get target file path
  local target_file = route.target.file
  if not target_file then
    return nil, "Route has no target file"
  end

  -- Construct full file path
  local file_path
  if target_file:sub(1, 8) == "content/" then
    -- Already has content/ prefix
    file_path = self.extract_path .. "/" .. target_file
  else
    -- Add content/ prefix
    file_path = self.extract_path .. "/content/" .. target_file
  end

  -- Check if file exists
  if not self.fs_adapter.file_exists(file_path) then
    return nil, "Target file does not exist: " .. file_path
  end

  -- Get MIME type
  local mime_type = _M.get_mime_type(file_path)

  return file_path, mime_type
end

-- Get package identifier (name-version)
function _M:get_identifier()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end

  if not self.metadata then
    return nil, "Metadata not loaded"
  end

  local name = self.metadata.name
  local version = self.metadata.version

  if not name or not version then
    return nil, "Metadata missing name or version"
  end

  return name .. "-" .. version
end

-- Get package metadata
function _M:get_metadata()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end

  return self.metadata
end

-- Get package routes
function _M:get_routes()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end

  return self.routes
end

-- Get package manifest
function _M:get_manifest()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end

  return self.manifest
end

return _M
