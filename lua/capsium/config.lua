-- capsium-lua Nginx glue: configuration loading
--
-- Loads config.json once at init and precomputes immutable per-mount views.
-- Request handling never mutates shared configuration: mount matching
-- returns the precomputed views (auto-mount views are memoized read-only).

local cjson = require "cjson"

local utils = require "capsium.utils"

local _M = {
  _VERSION = "0.2.0"
}

-- Default configuration file search paths
local DEFAULT_CONFIG_PATHS = {
  "/etc/capsium/config.json",
  "/etc/capsium/nginx/config.json",
  "/var/lib/capsium/config.json",
  "./config.json"
}

local DEFAULT_CONFIG = {
  package_dir = "/var/lib/capsium/packages",
  extract_dir = "/var/lib/capsium/extracted",
  cache_enabled = true,
  cache_ttl = 3600, -- seconds; TTL for the capsium_cache shared dict
  log_level = "info",
  packages_config_dir = "/etc/capsium/packages",
  mounts = {}
}

-- Default Cache-Control for static package resources (ARCHITECTURE.md
-- section 4); overridable per mount via options.cache_ttl or an explicit
-- options.headers["Cache-Control"].
local DEFAULT_STATIC_CACHE_CONTROL = "public, max-age=31536000"

-- Memoized synthesized views for auto-mounted packages (/capsium/<name>)
local auto_mounts = {}

local function file_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function read_json_file(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, "Failed to open file: " .. tostring(err)
  end

  local content = f:read("*all")
  f:close()

  local ok, data = pcall(cjson.decode, content)
  if not ok then
    return nil, "Failed to parse JSON: " .. tostring(data)
  end

  return data
end

-- Build an immutable mount view from a raw mount/package config entry.
local function build_mount_view(raw)
  local view = utils.deep_copy(raw)

  -- Normalize the package reference to a bare name (no .cap extension)
  if type(view.package) == "string" then
    view.name = view.package:gsub("%.cap$", "")
  end

  view.path = view.path or (view.name and ("/capsium/" .. view.name))
  view.options = view.options or {}
  view.headers = view.options.headers or view.headers or {}
  view.cors = view.options.cors
  view.cache_ttl = view.options.cache_ttl
  view.encryption = _M.normalize_encryption(view.options.encryption)

  -- Precompute the static Cache-Control header value for this mount
  if view.headers["Cache-Control"] then
    view.static_cache_control = view.headers["Cache-Control"]
  elseif view.cache_ttl then
    view.static_cache_control = "public, max-age=" .. tostring(view.cache_ttl)
  else
    view.static_cache_control = DEFAULT_STATIC_CACHE_CONTROL
  end

  return view
end

-- Load configuration.
--   options.config_path: explicit config file path
-- Falls back to $CAPSIUM_CONFIG_PATH, then the default search paths.
function _M.load(options)
  options = options or {}

  local config_path = options.config_path or os.getenv("CAPSIUM_CONFIG_PATH")

  if not config_path then
    for _, path in ipairs(DEFAULT_CONFIG_PATHS) do
      if file_exists(path) then
        config_path = path
        break
      end
    end
  end

  local raw = {}
  if config_path and file_exists(config_path) then
    local data, err = read_json_file(config_path)
    if data then
      raw = data
    else
      ngx.log(ngx.WARN, "Capsium: failed to load config from ", config_path,
              ": ", err)
    end
  end

  local config = utils.merge_tables(DEFAULT_CONFIG, raw)
  config.config_path = config_path

  -- Precompute mount views from the mounts array
  local mounts = {}
  for _, mount in ipairs(config.mounts or {}) do
    local view = build_mount_view(mount)
    if view.name and view.path then
      table.insert(mounts, view)
    end
  end

  -- Merge per-package config files (packages_config_dir/<name>.json)
  local lfs = require "lfs"
  local pcd = config.packages_config_dir
  if pcd then
    local attr = lfs.attributes(pcd)
    if attr and attr.mode == "directory" then
      for file in lfs.dir(pcd) do
        local name = file:match("^(.+)%.json$")
        if name then
          local data = read_json_file(pcd .. "/" .. file)
          if type(data) == "table" then
            data.package = data.package or name
            local view = build_mount_view(data)
            if view.name and view.path then
              table.insert(mounts, view)
            end
          end
        end
      end
    end
  end

  -- Longest path first for prefix matching
  table.sort(mounts, function(a, b) return #a.path > #b.path end)

  config.mounts = mounts
  return config
end

-- Normalize a JSON encryption config block
--   { "privateKeyPath": "/path/to/private.pem" }
-- to the core shape { private_key_path = ... }. Returns nil when unusable.
function _M.normalize_encryption(raw)
  if type(raw) ~= "table" then
    return nil
  end

  local path = raw.privateKeyPath or raw.private_key_path
  if type(path) ~= "string" or path == "" then
    return nil
  end

  return { private_key_path = path }
end

-- Match a path prefix: uri == path or uri starts with path .. "/"
local function path_matches(mount_path, uri)
  if uri == mount_path then
    return true
  end
  if mount_path == "/" then
    return true
  end
  return uri:sub(1, #mount_path + 1) == mount_path .. "/"
end

-- Resolve the mount view for a request by Host and URI path prefix.
-- Returns mount_view, subpath or nil. /api/v1/introspect is reserved and
-- never matches a package mount.
function _M.match_mount(config, host, uri)
  if uri:sub(1, 18) == "/api/v1/introspect" then
    return nil
  end

  local function subpath(mount_path)
    local rest = uri:sub(#mount_path + 1)
    if rest == "" then
      return "/"
    end
    if rest:sub(1, 1) ~= "/" then
      return "/" .. rest
    end
    return rest
  end

  -- Pass 1: mounts whose domain matches the request Host
  for _, mount in ipairs(config.mounts) do
    if mount.domain and mount.domain == host and
       path_matches(mount.path, uri) then
      return mount, subpath(mount.path)
    end
  end

  -- Pass 2: any configured mount matching the path (domain is advisory;
  -- a mount also answers on unmatched hosts)
  for _, mount in ipairs(config.mounts) do
    if path_matches(mount.path, uri) then
      return mount, subpath(mount.path)
    end
  end

  -- Auto-mount: /capsium/<package-name>[...] for any .cap in package_dir
  local name = uri:match("^/capsium/([^/]+)")
  if name then
    local view = auto_mounts[name]
    if not view then
      view = build_mount_view({
        package = name,
        path = "/capsium/" .. name
      })
      auto_mounts[name] = view
    end
    return view, subpath(view.path)
  end

  return nil
end

return _M
