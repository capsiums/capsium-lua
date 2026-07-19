-- capsium-lua Package Store Module
-- Framework-agnostic dependency resolution against a package store
-- (ARCHITECTURE.md section 4a)
--
-- A package store is a directory (config store_dir / env CAPSIUM_STORE)
-- containing <name>-<version>.cap files plus an optional index.json
-- (guid -> file). metadata.dependencies (guid -> semver range) resolve to
-- the newest satisfying version. Package identity (guid/version) is read
-- from each candidate's metadata.json; index.json supplies the guid when
-- metadata cannot be probed.

local cjson = require "cjson"

local semver = require "capsium.semver"

local _M = {
  _VERSION = "0.3.0"
}
local _M_mt = { __index = _M }

local INDEX_FILE = "index.json"

-- Create a store handle.
--   opts.store_dir (required): directory containing .cap files
--   opts.fs_adapter (required), opts.zip_adapter (required)
function _M.new(opts)
  opts = opts or {}

  if not opts.store_dir then
    return nil, "store_dir is required"
  end
  if not opts.fs_adapter then
    return nil, "fs_adapter is required"
  end
  if not opts.zip_adapter then
    return nil, "zip_adapter is required"
  end

  local self = {
    store_dir = opts.store_dir,
    fs_adapter = opts.fs_adapter,
    zip_adapter = opts.zip_adapter,
    _candidates = nil -- memoized scan
  }

  return setmetatable(self, _M_mt)
end

-- Probe a .cap for its metadata.json (guid/version/name).
local function probe_metadata(zip, path)
  local zfile = zip.open(path)
  if not zfile then
    return nil
  end

  local content = zip.read_file(zfile, "metadata.json")
  zip.close(zfile)
  if not content then
    return nil
  end

  local ok, metadata = pcall(cjson.decode, content)
  if not ok or type(metadata) ~= "table" then
    return nil
  end

  return metadata
end

-- Scan the store directory (memoized): array of
-- { guid, name, version, file }.
function _M:candidates()
  if self._candidates then
    return self._candidates
  end

  local fs = self.fs_adapter
  local zip = self.zip_adapter
  local candidates = {}

  local entries = fs.list_dir(self.store_dir) or {}

  -- Optional index: guid -> file name
  local index = {}
  local index_path = self.store_dir .. "/" .. INDEX_FILE
  local index_content = fs.read_file(index_path)
  if index_content then
    local ok, raw = pcall(cjson.decode, index_content)
    if ok and type(raw) == "table" then
      for guid, file in pairs(raw) do
        if type(guid) == "string" and type(file) == "string" then
          index[file] = guid
        end
      end
    end
  end

  for _, entry in ipairs(entries) do
    if entry:match("%.cap$") then
      local path = self.store_dir .. "/" .. entry
      local metadata = probe_metadata(zip, path)
      local guid = (metadata and metadata.guid) or index[entry]
      local version = metadata and metadata.version
      local name = (metadata and metadata.name)
                   or entry:match("^(.+)%-[^%-]+%.cap$")

      if guid and version then
        table.insert(candidates, {
          guid = guid,
          name = name,
          version = version,
          file = path
        })
      end
    end
  end

  table.sort(candidates, function(a, b)
    if a.guid ~= b.guid then
      return a.guid < b.guid
    end
    return a.version < b.version
  end)

  self._candidates = candidates
  return candidates
end

-- Resolve metadata.dependencies (guid -> semver range) to store
-- candidates, choosing the newest satisfying version per dependency.
-- Returns plan (guid -> candidate) | nil, err listing every
-- unsatisfiable dependency.
function _M:plan(dependencies)
  local candidates = self:candidates()
  local plan = {}
  local failures = {}

  -- Deterministic order: sorted guids
  local guids = {}
  for guid in pairs(dependencies or {}) do
    table.insert(guids, guid)
  end
  table.sort(guids)

  for _, guid in ipairs(guids) do
    local range = dependencies[guid]
    local versions = {}
    local by_version = {}
    for _, candidate in ipairs(candidates) do
      if candidate.guid == guid then
        table.insert(versions, candidate.version)
        by_version[candidate.version] = candidate
      end
    end

    local chosen = semver.newest_satisfying(versions, range)
    if not chosen then
      table.insert(failures, guid .. " (" .. tostring(range) .. ")")
    else
      plan[guid] = by_version[chosen]
    end
  end

  if #failures > 0 then
    return nil, "unsatisfiable package dependencies: " ..
                table.concat(failures, ", ")
  end

  return plan
end

return _M
