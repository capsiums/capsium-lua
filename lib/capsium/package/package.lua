-- capsium-lua Package Module
-- Framework-agnostic Capsium package representation (OOP via metatables)
--
-- Loads and normalizes the package descriptor files (ARCHITECTURE.md
-- sections 2-6), accepting both canonical and legacy gem forms:
--   metadata.json  (required; legacy array dependencies normalized to object)
--   manifest.json  (optional; auto-generated from content/ when absent)
--   routes.json    (optional; auto-generated from manifest+storage when absent)
--   storage.json   (optional)
--   security.json  (optional; SHA-256 integrity verification)

local cjson = require "cjson"

local mime = require "capsium.mime"
local router = require "capsium.package.router"
local security = require "capsium.package.security"
local csv = require "capsium.csv"

local _M = {
  _VERSION = "0.2.0"
}
local _M_mt = { __index = _M }

-- Create a new Package instance.
--   extract_path: directory containing the extracted package
--   opts.fs_adapter (required): file system adapter
--   opts.hash_fn (optional): function(file_path) -> sha256 hex; used for
--     integrity verification (defaults to the hash adapter)
function _M.new(extract_path, opts)
  if not extract_path then
    return nil, "extract_path is required"
  end

  opts = opts or {}
  if not opts.fs_adapter then
    return nil, "fs_adapter is required"
  end

  local self = {
    extract_path = extract_path,
    fs_adapter = opts.fs_adapter,
    hash_fn = opts.hash_fn,
    metadata = nil,
    manifest = nil,   -- normalized resources map
    routes = nil,     -- normalized routes array
    index = nil,      -- index resource path
    storage = nil,    -- normalized dataSets map
    _loaded = false
  }

  return setmetatable(self, _M_mt)
end

-- Decode a JSON file inside the package via the fs adapter.
local function read_json(fs, path)
  local content, err = fs.read_file(path)
  if not content then
    return nil, tostring(err or "unreadable")
  end

  local ok, data = pcall(cjson.decode, content)
  if not ok then
    return nil, "invalid JSON: " .. tostring(data)
  end

  return data
end

-- Normalize metadata dependencies: legacy array form
-- [{"name": ..., "version": ...}] becomes the canonical object form
-- {guid -> semver range}.
local function normalize_dependencies(metadata)
  local deps = metadata.dependencies
  if type(deps) ~= "table" then
    return metadata
  end

  -- Detect the legacy array form
  if #deps > 0 and type(deps[1]) == "table" and deps[1].name then
    local normalized = {}
    for _, dep in ipairs(deps) do
      if type(dep) == "table" and type(dep.name) == "string" then
        normalized[dep.name] = dep.version or "*"
      end
    end
    metadata.dependencies = normalized
  end

  return metadata
end

-- Load package data (metadata, manifest, storage, routes).
function _M:load()
  if self._loaded then
    return true
  end

  local fs = self.fs_adapter

  -- metadata.json (required)
  local metadata, merr = read_json(fs, self.extract_path .. "/metadata.json")
  if not metadata then
    return nil, "Failed to load metadata.json: " .. merr
  end
  if type(metadata.name) ~= "string" or type(metadata.version) ~= "string" then
    return nil, "Invalid metadata.json: missing name or version"
  end
  self.metadata = normalize_dependencies(metadata)

  -- manifest.json (auto-generated from content/ when absent or unusable)
  self.manifest = self:load_manifest()

  -- storage.json (optional)
  self.storage = self:load_storage()

  -- routes.json (auto-generated from manifest + storage when absent)
  local routes, rerr = self:load_routes()
  if not routes then
    return nil, "Failed to load routes: " .. (rerr or "unknown")
  end
  self.routes = routes

  self._loaded = true
  return true
end

-- Load and normalize manifest.json; auto-generate when missing/invalid.
function _M:load_manifest()
  local fs = self.fs_adapter
  local manifest_path = self.extract_path .. "/manifest.json"

  if fs.file_exists(manifest_path) then
    local raw = read_json(fs, manifest_path)
    local resources = raw and router.normalize_manifest(raw)
    if resources then
      return resources
    end
  end

  -- Auto-generate: scan content/ recursively (ARCHITECTURE.md section 3)
  return self:generate_manifest()
end

-- Generate a manifest resources map by scanning content/.
function _M:generate_manifest()
  local fs = self.fs_adapter
  local resources = {}
  local content_root = self.extract_path .. "/content"

  if not fs.dir_exists(content_root) then
    return resources
  end

  local function scan(dir, prefix)
    local entries = fs.list_dir(dir)
    if not entries then
      return
    end

    for _, entry in ipairs(entries) do
      if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
        local path = dir .. "/" .. entry
        local rel = prefix == "" and entry or (prefix .. "/" .. entry)

        if fs.dir_exists(path) then
          scan(path, rel)
        elseif fs.file_exists(path) then
          resources["content/" .. rel] = {
            type = mime.type_for(entry) or "application/octet-stream",
            visibility = "exported"
          }
        end
      end
    end
  end

  scan(content_root, "")
  return resources
end

-- Load and normalize storage.json (absent storage yields an empty map).
function _M:load_storage()
  local fs = self.fs_adapter
  local storage_path = self.extract_path .. "/storage.json"

  if not fs.file_exists(storage_path) then
    return {}
  end

  local raw = read_json(fs, storage_path)
  return router.normalize_storage(raw)
end

-- Load and normalize routes.json; auto-generate when absent.
function _M:load_routes()
  local fs = self.fs_adapter
  local routes_path = self.extract_path .. "/routes.json"

  if fs.file_exists(routes_path) then
    local raw, rerr = read_json(fs, routes_path)
    if not raw then
      return nil, "Failed to read routes.json: " .. rerr
    end

    local routes, index = router.normalize_routes(raw)
    if not routes then
      return nil, index -- second return carries the error message
    end

    -- Honor the index key: ensure "/" maps to the index resource
    if type(index) == "string" then
      self.index = index
      local has_root = false
      for _, route in ipairs(routes) do
        if route.path == "/" then
          has_root = true
          break
        end
      end
      if not has_root then
        table.insert(routes, 1, { path = "/", resource = index })
      end
    end

    return routes
  end

  -- Auto-generate from manifest + storage (ARCHITECTURE.md section 4)
  local index = self.manifest["content/index.html"] and "content/index.html"
  self.index = index
  return router.generate_routes(self.manifest, self.storage, index)
end

-- Resolve a request path to a servable target.
-- Returns one of:
--   { kind = "static", path = <abs path>, mime = <type>, headers = <t|nil> }
--   { kind = "dataset", dataset = <name> }
--   { kind = "handler" }   (dynamic route; reactors respond 501)
--   nil, err               when no route matches
function _M:resolve(request_path)
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end

  local route = router.resolve(self.routes, request_path)
  if not route then
    return nil, "Route not found: " .. tostring(request_path)
  end

  if route.dataset then
    return { kind = "dataset", dataset = route.dataset }
  end

  if route.handler then
    return { kind = "handler", method = route.method }
  end

  if not route.resource then
    return nil, "Route has no target: " .. tostring(request_path)
  end

  local file_path = self.extract_path .. "/" .. route.resource
  if not self.fs_adapter.file_exists(file_path) then
    return nil, "Target file does not exist: " .. route.resource
  end

  return {
    kind = "static",
    path = file_path,
    mime = router.resource_mime(self.manifest, route.resource)
           or "application/octet-stream",
    headers = route.headers
  }
end

-- Load a dataset by name. Supports JSON and CSV sources
-- (YAML is not supported by this reactor).
-- Returns data (decoded table), format ("json"|"csv") or nil, err.
function _M:get_dataset(name)
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end

  local ds = self.storage and self.storage[name]
  if not ds then
    return nil, "Unknown dataset: " .. tostring(name)
  end

  if ds.databaseFile then
    return nil, "SQLite datasets are not supported by this reactor: " .. name
  end

  if type(ds.source) ~= "string" then
    return nil, "Dataset has no source: " .. name
  end

  local content, rerr = self.fs_adapter.read_file(
    self.extract_path .. "/" .. ds.source)
  if not content then
    return nil, "Failed to read dataset source " .. ds.source ..
           ": " .. tostring(rerr)
  end

  local format = ds.format or ds.source:match("%.([^%.]+)$")
  format = format and format:lower()

  if format == "json" then
    local ok, data = pcall(cjson.decode, content)
    if not ok then
      return nil, "Failed to parse dataset " .. name .. ": " .. tostring(data)
    end
    return data, "json"
  elseif format == "csv" then
    local data, cerr = csv.to_objects(content)
    if not data then
      return nil, "Failed to parse dataset " .. name .. ": " .. cerr
    end
    return data, "csv"
  end

  return nil, "Unsupported dataset format for " .. name ..
         " (supported: json, csv)"
end

-- Verify package integrity against security.json (ARCHITECTURE.md section 6).
-- Returns valid (boolean), reason (nil when valid).
function _M:verify_integrity()
  local hash_fn = self.hash_fn
  if not hash_fn then
    hash_fn = require("capsium.adapters.hash").sha256_file_hex
  end

  local ok, reason = security.verify(self.extract_path, self.fs_adapter,
                                     hash_fn)
  if not ok then
    return false, reason
  end

  return true, nil
end

-- True when the package ships a security.json.
function _M:has_security()
  return self.fs_adapter.file_exists(self.extract_path .. "/security.json")
end

-- Package identifier (name-version).
function _M:get_identifier()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end

  return self.metadata.name .. "-" .. self.metadata.version
end

function _M:get_metadata()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end
  return self.metadata
end

function _M:get_routes()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end
  return self.routes
end

function _M:get_manifest()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end
  return self.manifest
end

function _M:get_storage()
  if not self._loaded then
    local ok, err = self:load()
    if not ok then
      return nil, err
    end
  end
  return self.storage
end

return _M
