-- capsium-lua Nginx glue: main entry point
--
-- Thin ngx layer over the framework-agnostic core (capsium.reactor,
-- capsium.package.*). All domain logic lives in lib/capsium; this module
-- only wires the nginx adapters into the core and translates to/from ngx.

local cjson = require "cjson"

local config_loader = require "capsium.config"
local nginx_adapter = require "capsium.adapters.nginx"
local hash_adapter = require "capsium.adapters.hash"
local auth_gate = require "capsium.auth_gate"
local Reactor = require "capsium.reactor"
local Registry = require "capsium.registry"

local _M = {
  _VERSION = "0.3.0"
}

local INTROSPECT_PREFIX = "/api/v1/introspect"

-- Module state (set once in init)
local config
local reactor
local cache -- ngx.shared.capsium_cache or nil
local registries = {} -- registry ref -> Registry instance | nil, err memo

local function log(level, ...)
  ngx.log(level, "Capsium: ", ...)
end

-- ---------------------------------------------------------------------------
-- Static registry pull (mount sources may be capsium://<guid>)
-- ---------------------------------------------------------------------------

-- resty.http-backed GET for remote registries; resty.http only loads
-- inside nginx workers (cosockets are unavailable in init context), which
-- is also why registry resolution is lazy (first request through the
-- mount).
local function http_get(url)
  local ok, http = pcall(require, "resty.http")
  if not ok then
    return nil, "resty.http unavailable"
  end

  local client = http.new()
  client:set_timeout(15000)
  local res, err = client:request_uri(url, {
    method = "GET",
    ssl_verify = true
  })
  if not res then
    return nil, err
  end
  return res.status, res.headers, res.body
end

-- Registry instances are memoized per reference (per worker).
local function registry_for(ref)
  local memo = registries[ref]
  if memo then
    return memo.registry, memo.err
  end

  local registry, err = Registry.new({
    ref = ref,
    fs_adapter = nginx_adapter.fs_adapter,
    http_get = http_get
  })
  registries[ref] = { registry = registry, err = err }
  return registry, err
end

-- Resolve a capsium:// mount: install the newest satisfying version from
-- the registry into the package store (sha256-verified against the
-- index; an up-to-date store file is reused) and switch the mount view
-- to the installed file. Failures are memoized on the mount and answered
-- with a typed 5xx.
local function resolve_registry_mount(mount)
  if mount.source_file or mount.resolve_error then
    return
  end

  local ref = mount.registry or config.registry
  if type(ref) ~= "string" or ref == "" then
    mount.resolve_error = "mount " .. mount.path .. " references " ..
      mount.source_guid .. " but no registry is configured (mount " ..
      "\"registry\" / top-level \"registry\" / CAPSIUM_REGISTRY)"
    mount.resolve_error_type = "not_configured"
    log(ngx.ERR, mount.resolve_error)
    return
  end

  local registry, rerr = registry_for(ref)
  if not registry then
    mount.resolve_error = "mount " .. mount.path .. ": " .. tostring(rerr)
    mount.resolve_error_type = "invalid"
    log(ngx.ERR, mount.resolve_error)
    return
  end

  local store_dir = mount.store or config.store_dir
  local path, err, etype = registry:install(mount.source_guid,
                                            mount.version_constraint or "*",
                                            store_dir)
  if not path then
    mount.resolve_error = "mount " .. mount.path .. " (" ..
      mount.source_guid .. "): " .. tostring(err)
    mount.resolve_error_type = etype
    log(ngx.ERR, mount.resolve_error)
    return
  end

  mount.source_file = path
  mount.name = path:match("([^/]+)%.cap$")
  log(ngx.INFO, "resolved ", mount.source_guid, " (",
      mount.version_constraint or "*", ") -> ", path)
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
    store_dir = config.store_dir,
    fs_adapter = nginx_adapter.fs_adapter,
    zip_adapter = nginx_adapter.zip_adapter,
    hash_fn = hash_adapter.sha256_file_hex,
    encryption = config_loader.normalize_encryption(config.encryption),
    logger = function(level, msg)
      local ngx_level = level == "warn" and ngx.WARN or ngx.ERR
      log(ngx_level, msg)
    end
  })

  if config.cache_enabled then
    cache = ngx.shared.capsium_cache
  end

  -- Registry-backed mounts (capsium:// sources): surface configuration
  -- problems at startup. The resolve/download itself is lazy (first
  -- request through the mount) because cosocket HTTP is unavailable in
  -- init context.
  for _, mount in ipairs(config.mounts) do
    if mount.source_guid then
      local ref = mount.registry or config.registry
      if type(ref) ~= "string" or ref == "" then
        log(ngx.ERR, "mount ", mount.path, " references ",
            mount.source_guid, " but no registry is configured (mount ",
            "\"registry\" / top-level \"registry\" / CAPSIUM_REGISTRY)")
      else
        local _, rerr = registry_for(ref)
        if rerr then
          log(ngx.ERR, "mount ", mount.path, ": ", rerr)
        end
      end
    end
  end

  _M.config = config
  _M.deploy_authentication =
    config_loader.normalize_authentication(config.authentication)

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

  -- Registry-backed mounts (capsium:// sources) resolve lazily: a
  -- sha256-verified install into the package store, then the normal
  -- mount flow serves the installed .cap
  if mount.source_guid and not mount.source_file then
    resolve_registry_mount(mount)
    if not mount.source_file then
      apply_cors_headers(mount)
      return respond_json(ngx.HTTP_INTERNAL_SERVER_ERROR, {
        error = mount.resolve_error,
        type = mount.resolve_error_type
      })
    end
  end

  -- Resolve and load the package (lazy extraction + integrity verification)
  local package, err, status = reactor:get_package(mount.name, {
    encryption = mount.encryption,
    source_file = mount.source_file
  })
  if not package then
    apply_cors_headers(mount)
    if status == "not_found" then
      return respond_error(ngx.HTTP_NOT_FOUND, "Package not found")
    end
    -- Extraction/integrity failure: reject with 5xx and the reason
    return respond_error(ngx.HTTP_INTERNAL_SERVER_ERROR,
                         tostring(err))
  end

  -- Authentication gate (section 4b): challenges, OAuth2 redirects and
  -- callbacks are answered by the gate itself; introspection stays open
  -- (it never reaches this handler)
  local authn = package:get_authentication()
  local principal = nil
  if authn then
    principal = auth_gate.gate(package, mount, subpath,
                               _M.deploy_authentication)
    if not principal then
      return -- the gate already answered the request
    end
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
    -- Route-level accessControl, enforced after authentication (4b).
    -- Without package authentication methods an authenticationRequired
    -- route always answers 401 (there is no way to authenticate).
    if not auth_gate.enforce_dataset_access(target, principal, authn) then
      return
    end

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

  -- Route-level headers (incl. section-4a responseHeaders /
  -- responseRewrite) override the mount Cache-Control default
  if target.headers then
    for name, value in pairs(target.headers) do
      ngx.header[name] = value
    end
  end
  if not (target.headers and target.headers["Cache-Control"])
     and not (mount.headers and mount.headers["Cache-Control"]) then
    ngx.header["Cache-Control"] = mount.static_cache_control
  end

  -- responseRewrite.body replaces the file content (section 4a)
  if target.body then
    ngx.print(target.body)
    return ngx.OK
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
