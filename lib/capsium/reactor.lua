-- Capsium Lua Library
-- Reactor core: manages a directory of Capsium packages
-- (framework-agnostic, OOP via metatables)
--
-- Packages are lazily extracted (with integrity verification) and loaded on
-- first use — a cold reactor still answers introspection for every .cap in
-- the package directory. Loaded packages are memoized per instance and
-- reloaded automatically when the .cap file changes.

local Package = require "capsium.package.package"
local Extractor = require "capsium.package.extractor"
local Store = require "capsium.package.store"
local utils = require "capsium.utils"

local _M = {
  _VERSION = "0.3.0"
}
local _M_mt = { __index = _M }

local function noop_logger() end

-- Create a reactor.
--   opts.package_dir (required): directory containing .cap files
--   opts.extract_dir (required): directory packages are extracted to
--   opts.fs_adapter (required), opts.zip_adapter (required)
--   opts.hash_fn (optional): sha256 file hash function
--   opts.crypto (optional): crypto module (signature verification, package
--     decryption); defaults to capsium.crypto
--   opts.encryption (optional): { private_key_path = ... } — default key
--     config for encrypted packages (section 6b)
--   opts.store_dir (optional): package store directory for composite
--     package dependency resolution (section 4a)
--   opts.logger (optional): function(level, message)
function _M.new(opts)
  opts = opts or {}

  if not opts.package_dir then
    return nil, "package_dir is required"
  end
  if not opts.extract_dir then
    return nil, "extract_dir is required"
  end
  if not opts.fs_adapter then
    return nil, "fs_adapter is required"
  end
  if not opts.zip_adapter then
    return nil, "zip_adapter is required"
  end

  local extractor = Extractor.new({
    fs_adapter = opts.fs_adapter,
    zip_adapter = opts.zip_adapter,
    hash_fn = opts.hash_fn,
    crypto = opts.crypto,
    encryption = opts.encryption
  })

  local self = {
    package_dir = opts.package_dir,
    extract_dir = opts.extract_dir,
    fs_adapter = opts.fs_adapter,
    zip_adapter = opts.zip_adapter,
    hash_fn = opts.hash_fn,
    crypto = opts.crypto,
    encryption = opts.encryption,
    store_dir = opts.store_dir,
    extractor = extractor,
    logger = opts.logger or noop_logger,
    _store = nil,      -- Store handle, created on first use
    _store_memo = {},  -- store file path -> { mtime, package|error }
    _memo = {} -- name\nkey -> { mtime = n, package = Package } or { mtime = n, error = msg }
  }

  return setmetatable(self, _M_mt)
end

-- List .cap packages in the package directory:
-- array of { name, path, size, modification_time }, sorted by name.
function _M:list_packages()
  local fs = self.fs_adapter
  local packages = {}

  local entries = fs.list_dir(self.package_dir)
  if not entries then
    return packages
  end

  for _, entry in ipairs(entries) do
    local name = entry:match("^(.+)%.cap$")
    if name then
      local path = self.package_dir .. "/" .. entry
      if fs.file_exists(path) then
        table.insert(packages, {
          name = name,
          path = path,
          modification_time = fs.get_mtime(path)
        })
      end
    end
  end

  table.sort(packages, function(a, b) return a.name < b.name end)
  return packages
end

-- Get a loaded package by name (without .cap extension).
-- Lazily extracts (with integrity verification) and loads the package.
--   call_opts.encryption (optional): per-package key config override
--     ({ private_key_path = ... }) for encrypted packages
-- Returns Package, or nil, err, status ("not_found" | "error").
--
-- Memoization is keyed by package name AND the effective key path, so a
-- package never gets served from an extraction produced under a different
-- decryption key.
function _M:get_package(name, call_opts)
  local fs = self.fs_adapter
  local package_path = self.package_dir .. "/" .. name .. ".cap"

  if not fs.file_exists(package_path) then
    return nil, "Package not found: " .. name, "not_found"
  end

  local key_path = self.extractor:effective_key_path(call_opts)
  local memo_key = name .. "\n" .. key_path

  local mtime = fs.get_mtime(package_path)
  local memo = self._memo[memo_key]
  if memo and memo.mtime == mtime then
    if memo.package then
      return memo.package
    end
    return nil, memo.error, "error"
  end

  -- Extract (atomic, integrity-verifying; decrypts encrypted packages)
  local extract_path, err = self.extractor:extract(package_path,
                                                   self.extract_dir,
                                                   call_opts)
  if not extract_path then
    self._memo[memo_key] = { mtime = mtime, error = err }
    self.logger("error", "Failed to extract " .. name .. ": " ..
                tostring(err))
    return nil, err, "error"
  end

  -- Load the package model
  local package = Package.new(extract_path, {
    fs_adapter = fs,
    hash_fn = self.hash_fn,
    crypto = self.crypto
  })

  local ok, lerr = package:load()
  if not ok then
    self._memo[memo_key] = { mtime = mtime, error = lerr }
    self.logger("error", "Failed to load " .. name .. ": " .. tostring(lerr))
    return nil, lerr, "error"
  end

  -- Composite packages (section 4a): resolve and mount dependencies
  local aok, aerr = self:attach_dependencies(package)
  if not aok then
    self._memo[memo_key] = { mtime = mtime, error = aerr }
    self.logger("error", "Failed to resolve dependencies of " .. name ..
                ": " .. tostring(aerr))
    return nil, aerr, "error"
  end

  self._memo[memo_key] = { mtime = mtime, package = package }
  return package
end

-- ---------------------------------------------------------------------------
-- Composite packages (ARCHITECTURE.md section 4a)
-- ---------------------------------------------------------------------------

-- Lazily create the package store handle.
local function store_for(self)
  if not self._store then
    self._store = Store.new({
      store_dir = self.store_dir,
      fs_adapter = self.fs_adapter,
      zip_adapter = self.zip_adapter
    })
  end
  return self._store
end

-- Resolve and mount a package's dependencies (no-op when the package
-- declares none). `visited` carries the ancestor guid chain for cycle
-- detection. Returns true | nil, err.
function _M:attach_dependencies(package, visited)
  local metadata = package:get_metadata()
  local dependencies = metadata and metadata.dependencies
  if type(dependencies) ~= "table" or not next(dependencies) then
    return true
  end

  if not self.store_dir then
    return nil, "Package declares dependencies but no package store is " ..
                "configured (store_dir / CAPSIUM_STORE)"
  end

  local plan, perr = store_for(self):plan(dependencies)
  if not plan then
    return nil, perr
  end

  -- The package itself joins the ancestor chain for its dependencies
  local chain = {}
  for guid in pairs(visited or {}) do
    chain[guid] = true
  end
  if type(metadata.guid) == "string" then
    chain[metadata.guid] = true
  end

  local attached = {}
  for guid, candidate in pairs(plan) do
    if chain[guid] then
      return nil, "Dependency cycle detected: " .. guid
    end

    local dependency, derr = self:load_store_package(candidate, chain)
    if not dependency then
      return nil, "Failed to load dependency " .. guid .. ": " ..
                  tostring(derr)
    end
    attached[guid] = dependency
  end

  package:set_dependencies(attached)
  return true
end

-- Extract and load a dependency from the store (memoized by file+mtime),
-- recursing into its own dependencies.
function _M:load_store_package(candidate, visited)
  local fs = self.fs_adapter
  local mtime = fs.get_mtime(candidate.file)

  local memo = self._store_memo[candidate.file]
  if memo and memo.mtime == mtime then
    if memo.package then
      return memo.package
    end
    return nil, memo.error
  end

  local extract_path, err = self.extractor:extract(candidate.file,
                                                   self.extract_dir)
  if not extract_path then
    self._store_memo[candidate.file] = { mtime = mtime, error = err }
    return nil, err
  end

  local package = Package.new(extract_path, {
    fs_adapter = fs,
    hash_fn = self.hash_fn,
    crypto = self.crypto
  })

  local ok, lerr = package:load()
  if not ok then
    self._store_memo[candidate.file] = { mtime = mtime, error = lerr }
    return nil, lerr
  end

  local aok, aerr = self:attach_dependencies(package, visited)
  if not aok then
    self._store_memo[candidate.file] = { mtime = mtime, error = aerr }
    return nil, aerr
  end

  self._store_memo[candidate.file] = { mtime = mtime, package = package }
  return package
end

-- Forget memoized packages (mainly useful for tests).
function _M:reset()
  self._memo = {}
end

-- ---------------------------------------------------------------------------
-- Introspection reports (ARCHITECTURE.md section 7)
-- ---------------------------------------------------------------------------

-- { packages = [{ name, version, author, description }] }
function _M:metadata_report()
  local list = {}

  for _, info in ipairs(self:list_packages()) do
    local package = self:get_package(info.name)
    if package then
      local metadata = package:get_metadata()
      table.insert(list, {
        name = metadata.name,
        version = metadata.version,
        author = metadata.author,
        description = metadata.description
      })
    end
  end

  return { packages = list }
end

-- { routes = [{ package, routes = [{ method, path }] }] }
function _M:routes_report()
  local list = {}

  for _, info in ipairs(self:list_packages()) do
    local package = self:get_package(info.name)
    if package then
      local entries = {}
      for _, route in ipairs(package:get_routes()) do
        table.insert(entries, {
          method = route.method or "GET",
          path = route.path
        })
      end
      table.insert(list, {
        package = info.name,
        routes = entries
      })
    end
  end

  return { routes = list }
end

-- { contentHashes = [{ package, hash }] } — SHA-256 of the .cap blob
function _M:content_hashes_report()
  local hash_fn = self.hash_fn
  if not hash_fn then
    hash_fn = require("capsium.adapters.hash").sha256_file_hex
  end

  local list = {}

  for _, info in ipairs(self:list_packages()) do
    local hex, err = hash_fn(info.path)
    if hex then
      table.insert(list, { package = info.name, hash = hex })
    else
      self.logger("warn", "Failed to hash " .. info.path .. ": " ..
                  tostring(err))
    end
  end

  return { contentHashes = list }
end

-- { contentValidity = [{ package, valid, lastChecked, reason? }] }
-- Reports the actual integrity verification result per package.
function _M:content_validity_report()
  local list = {}
  local now = utils.format_timestamp(os.time())

  for _, info in ipairs(self:list_packages()) do
    local package, err = self:get_package(info.name)

    if not package then
      table.insert(list, {
        package = info.name,
        valid = false,
        lastChecked = now,
        reason = err
      })
    else
      local valid, reason = package:verify_integrity()
      table.insert(list, {
        package = info.name,
        valid = valid and true or false,
        lastChecked = now,
        reason = reason
      })
    end
  end

  return { contentValidity = list }
end

return _M
