-- Capsium Lua Library
-- Static package registry (framework-agnostic)
--
-- Port of the Ruby gem's Capsium::Registry (0.4.0 parity): a static
-- registry is a directory or a static https base URL holding an
-- index.json plus .cap files stored relative to the registry root, so
-- any static host (GitHub Pages, S3, nginx) can serve it. Index shape:
--
--   { "packages": { "<guid>": { "name": "story-of-claire",
--     "versions": { "1.0.0": { "file": "story-of-claire-1.0.0.cap",
--                              "sha256": "<hex>", "size": 642047 } } } } }
--
-- A registry reference is a directory path (local, files read through
-- the fs adapter) or an http(s) base URL (remote, read-only; https
-- required — plain http is accepted for loopback hosts only, mirroring
-- the Ruby Registry::Remote). Remote bytes are fetched through the
-- injected http_get (the ngx glue wires resty.http, unit tests stub it);
-- redirects are followed up to MAX_REDIRECTS with the scheme revalidated
-- on every hop.
--
-- Errors are typed: failures return nil, message, type where type is
-- one of "not_configured" | "invalid" | "not_found" | "unsatisfiable" |
-- "checksum_mismatch" | "fetch" (the Ruby RegistryError hierarchy).

local cjson = require "cjson"

local semver = require "capsium.semver"

local _M = {
  _VERSION = "0.4.0"
}
local _M_mt = { __index = _M }

local INDEX_FILE = "index.json"
local MAX_REDIRECTS = 5

-- Write-temp-then-rename needs a per-process unique tmp name (concurrent
-- workers may install the same entry; the rename is atomic).
local tmp_counter = 0

-- ---------------------------------------------------------------------------
-- URL helpers (remote registries)
-- ---------------------------------------------------------------------------

-- scheme, host of an http(s) URL (userinfo and port stripped).
local function parse_authority(url)
  local scheme, rest = url:match("^(https?)://(.+)$")
  if not scheme then
    return nil, nil
  end

  local authority = rest:match("^([^/]*)") or ""
  authority = authority:match("^[^@]*@(.+)$") or authority -- userinfo
  local host
  if authority:sub(1, 1) == "[" then
    host = authority:match("^%[(.-)%]")
  else
    host = authority:match("^([^:]*)")
  end
  return scheme, host or ""
end

-- Loopback hosts may use plain http (local development), mirroring
-- Registry::Remote::LOOPBACK_NETWORKS + localhost names.
local function loopback_host(host)
  if type(host) ~= "string" then
    return false
  end
  host = host:lower()
  if host == "localhost" or host:match("%.localhost$") then
    return true
  end
  if host == "::1" then
    return true
  end
  return host:match("^127%.%d+%.%d+%.%d+$") ~= nil
end

-- Resolve a redirect Location against the current URL (absolute,
-- root-relative and path-relative forms).
local function join_url(base, location)
  if location:match("^https?://") then
    return location
  end
  local origin = base:match("^(https?://[^/]+)")
  if location:sub(1, 1) == "/" then
    return origin .. location
  end
  local dir = base:match("^(.*)/[^/]*$") or origin
  return dir .. "/" .. location
end

-- Create a registry handle for a reference.
--   opts.ref (required): registry directory path or https base URL
--   opts.fs_adapter (required)
--   opts.http_get (required for remote refs):
--     function(url) -> status, headers, body | nil, err
--   opts.hash_fn (optional): sha256 hex of a file path
--     (default capsium.adapters.hash.sha256_file_hex)
--   opts.hash_data_fn (optional): sha256 hex of a string
--     (default capsium.adapters.hash.sha256_hex)
-- Returns registry | nil, err, "not_configured" | "invalid".
function _M.new(opts)
  opts = opts or {}

  local ref = opts.ref
  if type(ref) ~= "string" or ref == "" then
    return nil, "no registry configured (mount registry / reactor " ..
                "registry / CAPSIUM_REGISTRY)", "not_configured"
  end
  if not opts.fs_adapter then
    return nil, "fs_adapter is required", "invalid"
  end

  local hash = require "capsium.adapters.hash"

  local self = {
    fs_adapter = opts.fs_adapter,
    http_get = opts.http_get,
    hash_fn = opts.hash_fn or hash.sha256_file_hex,
    hash_data_fn = opts.hash_data_fn or hash.sha256_hex,
    remote = ref:match("^https?://") ~= nil,
    _index = nil -- memoized parsed index.json
  }

  if self.remote then
    self.ref = ref:gsub("/+$", "")
    local scheme, host = parse_authority(self.ref)
    if scheme ~= "https" and not loopback_host(host) then
      return nil, "registry URL must use https (plain http for " ..
                  "loopback only): " .. self.ref, "invalid"
    end
    if type(self.http_get) ~= "function" then
      return nil, "http_get is required for a remote registry: " ..
                  self.ref, "invalid"
    end
  else
    self.ref = ref
    local fs = self.fs_adapter
    if fs.file_exists(ref) and not fs.dir_exists(ref) then
      return nil, "registry path is not a directory: " .. ref, "invalid"
    end
  end

  return setmetatable(self, _M_mt)
end

-- ---------------------------------------------------------------------------
-- Index loading
-- ---------------------------------------------------------------------------

local function parse_index(self, text, location)
  local ok, data = pcall(cjson.decode, text)
  if not ok or type(data) ~= "table" then
    return nil, location .. ": " .. INDEX_FILE .. " is not valid JSON",
           "invalid"
  end
  return data
end

-- The parsed index.json table | nil, err, type (memoized).
function _M:index()
  if self._index then
    return self._index
  end

  local data, err, etype
  if self.remote then
    local body, ferr = self:fetch_bytes(INDEX_FILE)
    if not body then
      -- An unreadable remote index makes the whole registry unusable
      -- (mirrors the Ruby Registry::Remote raising InvalidRegistryError)
      return nil, "no readable " .. INDEX_FILE .. " at " .. self.ref ..
                  ": " .. tostring(ferr), "invalid"
    end
    data, err, etype = parse_index(self, body, self.ref)
  else
    local path = self.ref .. "/" .. INDEX_FILE
    if self.fs_adapter.file_exists(path) then
      local content = self.fs_adapter.read_file(path, "rb")
      if not content then
        return nil, self.ref .. ": " .. INDEX_FILE .. " is unreadable",
               "invalid"
      end
      data, err, etype = parse_index(self, content, self.ref)
    else
      -- A local registry without an index is simply empty (mirrors the
      -- Ruby Registry::Local); resolution then reports not_found.
      data = { packages = {} }
    end
  end

  if not data then
    return nil, err, etype
  end
  if type(data.packages) ~= "table" then
    return nil, self.ref .. ": " .. INDEX_FILE ..
                " has no \"packages\" object", "invalid"
  end

  self._index = data
  return data
end

-- ---------------------------------------------------------------------------
-- Resolution
-- ---------------------------------------------------------------------------

-- The newest indexed version of `guid` satisfying `constraint`
-- (default "*"). Returns entry { guid, name, version, file, sha256,
-- size } | nil, err, "invalid" | "not_found" | "unsatisfiable".
function _M:resolve(guid, constraint)
  constraint = constraint or "*"

  local index, err, etype = self:index()
  if not index then
    return nil, err, etype
  end

  local listing = index.packages[guid]
  if type(listing) ~= "table" then
    return nil, "no package " .. guid .. " in registry " .. self.ref,
           "not_found"
  end

  local versions = listing.versions
  if type(versions) ~= "table" or not next(versions) then
    return nil, self.ref .. ": no versions indexed for " .. guid, "invalid"
  end

  local available = {}
  for version in pairs(versions) do
    if not semver.parse(version) then
      return nil, self.ref .. ": invalid version " .. tostring(version) ..
                  " for " .. guid, "invalid"
    end
    table.insert(available, version)
  end
  table.sort(available)

  local chosen = semver.newest_satisfying(available, constraint)
  if not chosen then
    return nil, "no version of " .. guid .. " satisfies '" .. constraint ..
                "' (registry has: " .. table.concat(available, ", ") .. ")",
           "unsatisfiable"
  end

  local data = versions[chosen]
  if type(data) ~= "table" or type(data.file) ~= "string"
     or type(data.sha256) ~= "string"
     or type(listing.name) ~= "string" then
    return nil, self.ref .. ": incomplete index entry for " .. guid .. " " ..
                chosen .. " (name/file/sha256)", "invalid"
  end

  return {
    guid = guid,
    name = listing.name,
    version = chosen,
    file = data.file,
    sha256 = data.sha256,
    size = tonumber(data.size) or 0
  }
end

-- The canonical store file name for an entry's .cap.
local function cap_file_name(entry)
  return entry.name .. "-" .. entry.version .. ".cap"
end

-- ---------------------------------------------------------------------------
-- Retrieval (subclass hooks of the Ruby port, unified here)
-- ---------------------------------------------------------------------------

-- Fetch a registry-relative file over http(s), following redirects.
-- Returns body | nil, err, "fetch" | "invalid".
function _M:fetch_bytes(relative_path)
  local url = self.ref .. "/" .. relative_path

  for _ = 1, MAX_REDIRECTS do
    local status, headers, body = self.http_get(url)
    if not status then
      return nil, "GET " .. url .. " failed: " .. tostring(headers), "fetch"
    end

    if status >= 200 and status < 300 then
      return body
    end

    local location = type(headers) == "table" and
                     (headers.location or headers.Location)
    if status >= 300 and status < 400 and type(location) == "string" then
      url = join_url(url, location)
      local scheme, host = parse_authority(url)
      if scheme ~= "https" and not loopback_host(host) then
        return nil, "registry URL must use https (plain http for " ..
                    "loopback only): " .. url, "invalid"
      end
    else
      return nil, "GET " .. url .. " failed: HTTP " .. tostring(status),
             "fetch"
    end
  end

  return nil, "GET " .. self.ref .. "/" .. relative_path ..
              ": too many redirects (limit " .. MAX_REDIRECTS .. ")", "fetch"
end

-- The bytes of an entry's .cap: read from the registry directory for a
-- local registry, fetched over http(s) for a remote one.
-- Returns content | nil, err, type.
function _M:entry_bytes(entry)
  if self.remote then
    return self:fetch_bytes(entry.file)
  end

  local path = self.ref .. "/" .. entry.file
  if not self.fs_adapter.file_exists(path) then
    return nil, self.ref .. ": indexed file missing: " .. entry.file,
           "invalid"
  end

  local content, err = self.fs_adapter.read_file(path, "rb")
  if not content then
    return nil, self.ref .. ": cannot read " .. entry.file .. ": " ..
                tostring(err), "fetch"
  end
  return content
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

-- Resolve the newest satisfying version, fetch its .cap (verifying the
-- sha256 declared in the index) and install it into the package store
-- as "<name>-<version>.cap". A store file that already matches the
-- indexed sha256 is reused as-is (store reuse across restarts).
-- Returns the installed store path | nil, err, type.
function _M:install(guid, constraint, store_dir)
  if type(store_dir) ~= "string" or store_dir == "" then
    return nil, "store_dir is required to install from a registry",
           "not_configured"
  end

  local entry, err, etype = self:resolve(guid, constraint)
  if not entry then
    return nil, err, etype
  end

  local fs = self.fs_adapter
  local target = store_dir .. "/" .. cap_file_name(entry)

  -- Store reuse: an existing file with a matching sha256 is left alone.
  if fs.file_exists(target) then
    local existing = self.hash_fn(target)
    if existing and existing:lower() == entry.sha256:lower() then
      return target
    end
  end

  local content, berr, betype = self:entry_bytes(entry)
  if not content then
    return nil, berr, betype
  end

  local actual = self.hash_data_fn(content)
  if actual:lower() ~= entry.sha256:lower() then
    return nil, "sha256 mismatch for " .. cap_file_name(entry) ..
                " from " .. self.ref .. ": index declares " ..
                entry.sha256 .. ", file hashes to " .. actual,
           "checksum_mismatch"
  end

  if not fs.dir_exists(store_dir) then
    local ok, merr = fs.mkdir_p(store_dir)
    if not ok then
      return nil, "cannot create store directory " .. store_dir .. ": " ..
                  tostring(merr), "fetch"
    end
  end

  tmp_counter = tmp_counter + 1
  local tmp = target .. ".tmp-" .. tostring(tmp_counter) .. "-" ..
              tostring(os.time())
  local ok, werr = fs.write_file(tmp, content, "wb")
  if not ok then
    return nil, "cannot write " .. tmp .. ": " .. tostring(werr), "fetch"
  end
  local rok, rerr = fs.rename(tmp, target)
  if not rok then
    fs.remove(tmp)
    return nil, tostring(rerr), "fetch"
  end

  return target
end

return _M
