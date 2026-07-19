-- Capsium Lua Library
-- Manifest/routes/storage normalization and route auto-generation
-- (framework-agnostic, pure functions)
--
-- Accepts BOTH canonical forms (ARCHITECTURE.md sections 3-5) and legacy
-- gem forms, normalizing everything to the canonical shapes on read:
--   manifest: canonical {"resources": {path: {type, visibility?}}}
--             legacy   {"content": [{file, mime}, ...]} or {"content": {name: mime}}
--   routes:   canonical {"index": path?, "routes": [{path, resource|dataset|handler...}]}
--             legacy   {"routes": [{path, target: {file|dataset}}]} (array)
--             legacy   {"routes": {path: {target: {file|dataset}}}} (object)
--   storage:  canonical {"storage": {"dataSets": {name: {source, ...}}}}
--             legacy   {"datasets": [{name, source, format, schema}]}

local mime = require "capsium.mime"

local _M = {
  _VERSION = "0.4.0"
}

-- ---------------------------------------------------------------------------
-- Manifest
-- ---------------------------------------------------------------------------

-- Normalize a parsed manifest.json table to the canonical resources map:
-- { ["content/index.html"] = { type = "text/html", visibility = "exported" } }
-- Returns nil when the input does not look like a manifest at all.
function _M.normalize_manifest(raw)
  if type(raw) ~= "table" then
    return nil
  end

  -- Canonical form
  if type(raw.resources) == "table" then
    local resources = {}
    for path, info in pairs(raw.resources) do
      if type(info) == "table" and type(info.type) == "string" then
        resources[path] = {
          type = info.type,
          visibility = info.visibility or "exported",
          version = info.version
        }
      end
    end
    return resources
  end

  -- Legacy form: {"content": [{file, mime}, ...]}
  if type(raw.content) == "table" then
    local resources = {}

    -- Legacy array variant
    for _, entry in ipairs(raw.content) do
      if type(entry) == "table" and type(entry.file) == "string"
         and type(entry.mime) == "string" then
        resources["content/" .. entry.file] = {
          type = entry.mime,
          visibility = "exported"
        }
      end
    end

    -- Legacy object variant: {"content": {"index.html": "text/html"}}
    for name, mtype in pairs(raw.content) do
      if type(name) == "string" and type(mtype) == "string" then
        resources["content/" .. name] = {
          type = mtype,
          visibility = "exported"
        }
      end
    end

    if next(resources) then
      return resources
    end
  end

  return nil
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

-- Normalize a parsed storage.json table to the canonical dataSets map:
-- { ["animals"] = { source = "data/animals.json", ... } }
-- Absent storage is not an error: returns an empty map.
function _M.normalize_storage(raw)
  local datasets = {}

  if type(raw) ~= "table" then
    return datasets
  end

  -- Canonical form
  if type(raw.storage) == "table" and type(raw.storage.dataSets) == "table" then
    for name, ds in pairs(raw.storage.dataSets) do
      if type(ds) == "table" then
        local copy = {}
        for k, v in pairs(ds) do
          copy[k] = v
        end
        datasets[name] = copy
      end
    end
    return datasets
  end

  -- Legacy form: {"datasets": [{name, source, format, schema}, ...]}
  if type(raw.datasets) == "table" then
    for _, ds in ipairs(raw.datasets) do
      if type(ds) == "table" and type(ds.name) == "string" then
        datasets[ds.name] = {
          source = ds.source,
          format = ds.format,
          schema = ds.schema
        }
      end
    end
  end

  return datasets
end

-- ---------------------------------------------------------------------------
-- Storage layers (ARCHITECTURE.md section 5a)
-- ---------------------------------------------------------------------------

-- Normalize layered storage config to an array (bottom -> top) of
--   { path = "base", writable = false, visibility = "exported" }
-- Canonical source: storage.json's storage.layers. The manifest.json
-- top-level "layers" form (05x-storage) is accepted on read as well.
-- Entries with unsafe paths (absolute, "..") or no string path are
-- skipped. Returns nil when no usable layers are configured.
function _M.normalize_layers(raw)
  local layers

  if type(raw) == "table" then
    if type(raw.storage) == "table" and type(raw.storage.layers) == "table" then
      layers = raw.storage.layers
    elseif type(raw.layers) == "table" then
      layers = raw.layers
    end
  end

  if not layers then
    return nil
  end

  local normalized = {}
  for _, layer in ipairs(layers) do
    if type(layer) == "table" and type(layer.path) == "string"
       and layer.path ~= ""
       and layer.path:sub(1, 1) ~= "/"
       and not layer.path:find("%.%.") then
      table.insert(normalized, {
        path = layer.path,
        writable = layer.writable == true,
        visibility = layer.visibility == "private" and "private" or "exported"
      })
    end
  end

  if #normalized == 0 then
    return nil
  end

  return normalized
end

-- ---------------------------------------------------------------------------
-- Routes
-- ---------------------------------------------------------------------------

-- Normalize one legacy route target to a package-relative resource path.
-- Legacy targets are relative to content/ unless they already carry the
-- content/ prefix.
local function normalize_legacy_resource(target_file)
  if target_file:sub(1, 8) == "content/" then
    return target_file
  end
  return "content/" .. target_file
end

-- Normalize a parsed routes.json table to:
--   routes: array of { path = ..., resource = ... } | { path = ..., dataset = ... }
--           | { path = ..., method = ..., handler = ... } (accepted, served 501)
--   index:  package-relative index resource path or nil
-- Returns nil, err when the input has no usable routes property.
function _M.normalize_routes(raw)
  if type(raw) ~= "table" or type(raw.routes) ~= "table" then
    return nil, "Invalid routes.json: missing or invalid 'routes' property"
  end

  local routes = {}

  -- Array form (canonical and legacy)
  for _, entry in ipairs(raw.routes) do
    if type(entry) == "table" and type(entry.path) == "string" then
      if type(entry.resource) == "string" then
        -- Canonical static route; resource is package-relative (or a
        -- capsium://<guid>/<path> dependency reference, section 4a)
        table.insert(routes, {
          -- Route inheritance: remap is the effective served path
          path = type(entry.remap) == "string" and entry.remap
                 or entry.path,
          original_path = entry.remap ~= nil and entry.path or nil,
          resource = entry.resource,
          headers = entry.headers,
          visibility = entry.visibility,
          remap = entry.remap,
          responseRewrite = entry.responseRewrite,
          responseHeaders = entry.responseHeaders,
          requestHeaders = entry.requestHeaders
        })
      elseif type(entry.dataset) == "string" then
        -- Dataset route
        table.insert(routes, {
          path = entry.path,
          dataset = entry.dataset,
          accessControl = entry.accessControl
        })
      elseif type(entry.target) == "table"
             and type(entry.target.file) == "string" then
        -- Legacy static route; target is relative to content/
        table.insert(routes, {
          path = entry.path,
          resource = normalize_legacy_resource(entry.target.file)
        })
      elseif type(entry.target) == "table"
             and type(entry.target.dataset) == "string" then
        -- Legacy dataset route (target.dataset form)
        table.insert(routes, {
          path = entry.path,
          dataset = entry.target.dataset,
          accessControl = entry.accessControl
        })
      elseif entry.handler ~= nil then
        -- Dynamic handler route: accepted, resolved as 501 by reactors
        table.insert(routes, {
          path = entry.path,
          method = entry.method,
          handler = entry.handler
        })
      end
    end
  end

  -- Legacy object form: {"routes": {"/path": {target: {file|dataset}}}}
  for path, entry in pairs(raw.routes) do
    if type(path) == "string" and type(entry) == "table"
       and type(entry.target) == "table" then
      if type(entry.target.file) == "string" then
        table.insert(routes, {
          path = path,
          resource = normalize_legacy_resource(entry.target.file)
        })
      elseif type(entry.target.dataset) == "string" then
        table.insert(routes, {
          path = path,
          dataset = entry.target.dataset,
          accessControl = entry.accessControl
        })
      end
    end
  end

  if #routes == 0 then
    return nil, "Invalid routes.json: no usable route entries"
  end

  return routes, raw.index
end

-- ---------------------------------------------------------------------------
-- Route auto-generation (ARCHITECTURE.md section 4)
-- ---------------------------------------------------------------------------

-- Auto-generate routes from a normalized manifest resources map and a
-- normalized storage dataSets map.
--
-- Rules (per 05x-routing):
--   * index -> content/index.html (or the given index resource)
--   * every manifest resource under content/ gets a route with its path
--     relative to content/
--   * HTML files get TWO routes: basename without extension AND full filename
--   * the index HTML additionally gets "/"
--   * every dataset gets /api/v1/data/<id>
--
-- Deterministic output order: "/" first (when an index exists), then content
-- routes sorted by path, then dataset routes sorted by id.
function _M.generate_routes(resources, datasets, index)
  resources = resources or {}
  datasets = datasets or {}
  index = index or "content/index.html"

  local routes = {}
  local emitted = {} -- dedupe by path

  local function emit(path, resource)
    if not emitted[path] then
      emitted[path] = true
      table.insert(routes, { path = path, resource = resource })
    end
  end

  -- Collect content resource paths, sorted for determinism.
  local content_paths = {}
  for path in pairs(resources) do
    if path:sub(1, 8) == "content/" then
      table.insert(content_paths, path)
    end
  end
  table.sort(content_paths)

  local has_index = resources[index] ~= nil

  if has_index then
    emit("/", index)
  end

  for _, path in ipairs(content_paths) do
    local rel = path:sub(9) -- strip "content/"
    local route_path = "/" .. rel
    emit(route_path, path)

    -- HTML dual route: basename without extension
    local basename = rel:match("^(.+)%.html?$")
    if basename and basename ~= "" then
      emit("/" .. basename, path)
    end
  end

  -- Dataset routes
  local names = {}
  for name in pairs(datasets) do
    table.insert(names, name)
  end
  table.sort(names)

  for _, name in ipairs(names) do
    table.insert(routes, { path = "/api/v1/data/" .. name, dataset = name })
  end

  return routes
end

-- ---------------------------------------------------------------------------
-- Route resolution
-- ---------------------------------------------------------------------------

-- Find a route entry for a request path. Tries the exact path, then with a
-- trailing slash added/removed (kept for backwards compatibility).
function _M.resolve(routes, request_path)
  if type(routes) ~= "table" then
    return nil
  end

  local function find(path)
    for _, route in ipairs(routes) do
      if route.path == path then
        return route
      end
    end
    return nil
  end

  local route = find(request_path)

  if not route and request_path:sub(-1) ~= "/" then
    route = find(request_path .. "/")
  end

  if not route and request_path:sub(-1) == "/" and #request_path > 1 then
    route = find(request_path:sub(1, -2))
  end

  return route
end

-- MIME type for a route's resource: the extension-derived type wins when
-- known (legacy gem manifests sometimes carry wrong types); the manifest
-- entry is the fallback.
function _M.resource_mime(resources, resource_path)
  local by_extension = mime.type_for(resource_path)
  if by_extension then
    return by_extension
  end

  local info = resources and resources[resource_path]
  if info and info.type then
    return info.type
  end

  return nil
end

return _M
