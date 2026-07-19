-- capsium-lua Nginx glue: main entry point
--
-- Thin ngx layer over the framework-agnostic core (capsium.reactor,
-- capsium.package.*). All domain logic lives in lib/capsium; this module
-- only wires the nginx adapters into the core and translates to/from ngx.

local cjson = require "cjson"

local config_loader = require "capsium.config"
local nginx_adapter = require "capsium.adapters.nginx"
local hash_adapter = require "capsium.adapters.hash"
local Reactor = require "capsium.reactor"

local _M = {
  _VERSION = "0.2.0"
}

local INTROSPECT_PREFIX = "/api/v1/introspect"

-- Module state (set once in init)
local config
local reactor
local cache -- ngx.shared.capsium_cache or nil

local function log(level, ...)
  ngx.log(level, "Capsium: ", ...)
end

-- Initialize the module. Called from init_by_lua_block.
function _M.init(options)
  options = options or {}

  config = config_loader.load(options)

  local function ensure_dir(path)
    if not nginx_adapter.fs_adapter.dir_exists(path) then
      local ok, err = nginx_adapter.fs_adapter.mkdir_p(path)
      if not ok then
        return nil, err
      end
    end
    return true
  end

  for _, dir in ipairs({ config.package_dir, config.extract_dir }) do
    local ok, err = ensure_dir(dir)
    if not ok then
      log(ngx.ERR, "failed to create directory ", dir, ": ", err)
      return false, err
    end
  end

  reactor = Reactor.new({
    package_dir = config.package_dir,
    extract_dir = config.extract_dir,
    fs_adapter = nginx_adapter.fs_adapter,
    zip_adapter = nginx_adapter.zip_adapter,
    hash_fn = hash_adapter.sha256_file_hex,
    logger = function(level, msg)
      local ngx_level = level == "warn" and ngx.WARN or ngx.ERR
      log(ngx_level, msg)
    end
  })

  if config.cache_enabled then
    cache = ngx.shared.capsium_cache
  end

  _M.config = config

  log(ngx.INFO, "initialized (config: ", config.config_path or "defaults",
      ", mounts: ", #config.mounts, ")")
  return true
end

-- ---------------------------------------------------------------------------
-- Response helpers
-- ---------------------------------------------------------------------------

local function respond_json(status, data)
  ngx.status = status
  ngx.header.content_type = "application/json"
  ngx.say(cjson.encode(data))
  return ngx.exit(status)
end

local function respond_error(status, message)
  return respond_json(status, { error = message })
end

-- ---------------------------------------------------------------------------
-- CORS
-- ---------------------------------------------------------------------------

local function origin_allowed(cors, origin)
  if not cors or type(cors.allowed_origins) ~= "table" then
    return false
  end
  for _, allowed in ipairs(cors.allowed_origins) do
    if allowed == "*" or allowed == origin then
      return true, allowed == "*"
    end
  end
  return false
end

-- Apply CORS response headers for simple/actual requests.
local function apply_cors_headers(mount)
  local cors = mount.cors
  if not cors then
    return
  end

  local origin = ngx.var.http_origin
  if not origin then
    return
  end

  local allowed, wildcard = origin_allowed(cors, origin)
  if allowed then
    ngx.header["Access-Control-Allow-Origin"] = wildcard and "*" or origin
    if type(cors.expose_headers) == "table" then
      ngx.header["Access-Control-Expose-Headers"] =
        table.concat(cors.expose_headers, ", ")
    end
  end
end

-- Answer a CORS preflight (OPTIONS) request.
local function handle_preflight(mount)
  local cors = mount.cors
  local origin = ngx.var.http_origin
  local allowed = origin and origin_allowed(cors, origin)

  if allowed then
    local _, wildcard = origin_allowed(cors, origin)
    ngx.header["Access-Control-Allow-Origin"] = wildcard and "*" or origin
  end
  if type(cors.allowed_methods) == "table" then
    ngx.header["Access-Control-Allow-Methods"] =
      table.concat(cors.allowed_methods, ", ")
  end
  if type(cors.allowed_headers) == "table" then
    ngx.header["Access-Control-Allow-Headers"] =
      table.concat(cors.allowed_headers, ", ")
  end
  if cors.max_age then
    ngx.header["Access-Control-Max-Age"] = tostring(cors.max_age)
  end

  ngx.status = ngx.HTTP_NO_CONTENT
  return ngx.exit(ngx.HTTP_NO_CONTENT)
end

-- ---------------------------------------------------------------------------
-- Request handling (package serving)
-- ---------------------------------------------------------------------------

function _M.handle_request()
  local mount, subpath = config_loader.match_mount(config, ngx.var.host,
                                                   ngx.var.uri)
  if not mount then
    return respond_error(ngx.HTTP_NOT_FOUND, "Not found")
  end

  local method = ngx.req.get_method()

  -- CORS preflight
  if method == "OPTIONS" and mount.cors then
    return handle_preflight(mount)
  end

  -- Package routes are GET-only (HEAD is served like GET, without a body)
  if method ~= "GET" and method ~= "HEAD" then
    apply_cors_headers(mount)
    ngx.header["Allow"] = "GET, HEAD"
    return respond_error(ngx.HTTP_NOT_ALLOWED,
                         "Method not allowed")
  end

  -- Resolve and load the package (lazy extraction + integrity verification)
  local package, err, status = reactor:get_package(mount.name)
  if not package then
    apply_cors_headers(mount)
    if status == "not_found" then
      return respond_error(ngx.HTTP_NOT_FOUND, "Package not found")
    end
    -- Extraction/integrity failure: reject with 5xx and the reason
    return respond_error(ngx.HTTP_INTERNAL_SERVER_ERROR,
                         tostring(err))
  end

  -- Resolve the route
  local target, rerr = package:resolve(subpath)
  if not target then
    apply_cors_headers(mount)
    return respond_error(ngx.HTTP_NOT_FOUND, tostring(rerr))
  end

  -- Dynamic handler routes are out of scope (ARCHITECTURE.md section 4)
  if target.kind == "handler" then
    apply_cors_headers(mount)
    return respond_error(ngx.HTTP_NOT_IMPLEMENTED,
                         "Dynamic handler routes are not implemented")
  end

  -- Per-mount custom headers
  if mount.headers then
    for name, value in pairs(mount.headers) do
      ngx.header[name] = value
    end
  end
  apply_cors_headers(mount)

  if target.kind == "dataset" then
    local data, derr = package:get_dataset(target.dataset)
    if not data then
      return respond_error(ngx.HTTP_INTERNAL_SERVER_ERROR, tostring(derr))
    end
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(data))
    return ngx.OK
  end

  -- Static resource
  ngx.header.content_type = target.mime

  -- Cache-Control: route headers < mount Cache-Control default
  local cache_control = mount.static_cache_control
  if target.headers and target.headers["Cache-Control"] then
    cache_control = target.headers["Cache-Control"]
  end
  if not (mount.headers and mount.headers["Cache-Control"]) then
    ngx.header["Cache-Control"] = cache_control
  end

  local content, ferr = nginx_adapter.fs_adapter.read_file(target.path, "rb")
  if not content then
    return respond_error(ngx.HTTP_INTERNAL_SERVER_ERROR,
                         "Failed to read " .. tostring(target.path) ..
                         ": " .. tostring(ferr))
  end

  ngx.print(content)
  return ngx.OK
end

-- ---------------------------------------------------------------------------
-- Introspection API (/api/v1/introspect/*)
-- ---------------------------------------------------------------------------

local introspect_handlers = {
  ["/metadata"] = function() return reactor:metadata_report() end,
  ["/routes"] = function() return reactor:routes_report() end,
  ["/content-hashes"] = function() return reactor:content_hashes_report() end,
  ["/content-validity"] = function() return reactor:content_validity_report() end
}

function _M.handle_introspection()
  if ngx.req.get_method() ~= "GET" then
    ngx.header["Allow"] = "GET"
    return respond_error(ngx.HTTP_NOT_ALLOWED,
                         "Method not allowed")
  end

  local sub = ngx.var.uri:sub(#INTROSPECT_PREFIX + 1)
  local handler = introspect_handlers[sub]
  if not handler then
    return respond_error(ngx.HTTP_NOT_FOUND, "Not found")
  end

  -- Shared-dict cache (capsium_cache) with TTL from config
  local cache_key = "introspect:" .. sub
  if cache then
    local cached = cache:get(cache_key)
    if cached then
      ngx.header.content_type = "application/json"
      ngx.say(cached)
      return ngx.OK
    end
  end

  local body = cjson.encode(handler())

  if cache then
    cache:set(cache_key, body, config.cache_ttl)
  end

  ngx.header.content_type = "application/json"
  ngx.say(body)
  return ngx.OK
end

return _M
