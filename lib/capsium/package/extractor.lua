-- capsium-lua Package Extractor Module
-- Framework-agnostic package extraction (OOP via metatables)
--
-- Extraction is atomic: archives unpack into a temporary directory that is
-- renamed into place only after metadata.json parses and security.json
-- checksums verify (ARCHITECTURE.md section 6, reject on mismatch).

local cjson = require "cjson"

local security = require "capsium.package.security"

local _M = {
  _VERSION = "0.2.0"
}
local _M_mt = { __index = _M }

-- Create an extractor.
--   opts.fs_adapter (required): file system adapter
--   opts.zip_adapter (required): zip archive adapter
--   opts.hash_fn (optional): function(file_path) -> sha256 hex
--   opts.crypto (optional): crypto module for signature verification and
--     package decryption (defaults to capsium.crypto)
function _M.new(opts)
  opts = opts or {}

  if not opts.fs_adapter then
    return nil, "fs_adapter is required"
  end
  if not opts.zip_adapter then
    return nil, "zip_adapter is required"
  end

  local self = {
    fs_adapter = opts.fs_adapter,
    zip_adapter = opts.zip_adapter,
    hash_fn = opts.hash_fn,
    crypto = opts.crypto
  }

  return setmetatable(self, _M_mt)
end

-- Default hash function (lazy require to keep the adapter swappable)
local function default_hash_fn()
  return require("capsium.adapters.hash").sha256_file_hex
end

-- Default crypto module (lazy require to keep it swappable)
local function default_crypto()
  return require "capsium.crypto"
end

-- Remove a directory tree using fs adapter primitives.
function _M:remove_tree(path)
  local fs = self.fs_adapter

  if fs.file_exists(path) then
    return fs.remove(path)
  end

  if not fs.dir_exists(path) then
    return true
  end

  local entries = fs.list_dir(path)
  if entries then
    for _, entry in ipairs(entries) do
      if entry ~= "." and entry ~= ".." then
        local ok, err = self:remove_tree(path .. "/" .. entry)
        if not ok then
          return nil, err
        end
      end
    end
  end

  return fs.remove(path)
end

-- Check whether a package is already extracted and up to date.
-- Returns true, extract_path when usable; false, reason otherwise.
function _M:is_extracted(package_path, extract_dir)
  local fs = self.fs_adapter

  if not fs.file_exists(package_path) then
    return false, "Package file does not exist"
  end

  local package_name = package_path:match("([^/]+)%.cap$")
  if not package_name then
    return false, "Invalid package filename (must end with .cap)"
  end

  local extract_path = extract_dir .. "/" .. package_name
  local metadata_path = extract_path .. "/metadata.json"

  if not fs.file_exists(metadata_path) then
    return false, "Package not extracted"
  end

  local package_mtime = fs.get_mtime(package_path)
  local metadata_mtime = fs.get_mtime(metadata_path)

  if not package_mtime or not metadata_mtime then
    return false, "Failed to get modification times"
  end

  if package_mtime > metadata_mtime then
    return false, "Package file is newer than extracted files"
  end

  return true, extract_path
end

-- Extract a Capsium package (.cap zip) into extract_dir/<name>.
-- Returns extract_path or nil, err. On integrity mismatch the package is
-- rejected: nothing is left at the final extract path.
function _M:extract(package_path, extract_dir)
  local fs = self.fs_adapter
  local zip = self.zip_adapter

  -- Already extracted and up to date?
  local is_extracted, result = self:is_extracted(package_path, extract_dir)
  if is_extracted then
    return result
  end

  local package_name = package_path:match("([^/]+)%.cap$")
  if not package_name then
    return nil, "Invalid package filename (must end with .cap)"
  end

  local final_path = extract_dir .. "/" .. package_name
  local tmp_path = extract_dir .. "/.tmp-" .. package_name

  -- Clean stale temporary directory from a previous failed extraction
  if fs.dir_exists(tmp_path) then
    self:remove_tree(tmp_path)
  end

  local ok, err = fs.mkdir_p(tmp_path)
  if not ok then
    return nil, "Failed to create extract directory: " .. (err or "unknown")
  end

  local function fail(message)
    self:remove_tree(tmp_path)
    return nil, message
  end

  -- Open the zip archive
  local zfile, zerr = zip.open(package_path)
  if not zfile then
    return fail("Failed to open package as zip: " .. (zerr or "unknown"))
  end

  local files, lerr = zip.list_files(zfile)
  if not files then
    zip.close(zfile)
    return fail("Failed to list files in package: " .. (lerr or "unknown"))
  end

  -- Extract every file, guarding against zip-slip path traversal
  for _, filename in ipairs(files) do
    if not filename:match("/$") then
      if filename:find("%.%.") then
        zip.close(zfile)
        return fail("Refusing to extract unsafe path: " .. filename)
      end

      local dir = filename:match("(.*)/")
      if dir and dir ~= "" then
        local mok, merr = fs.mkdir_p(tmp_path .. "/" .. dir)
        if not mok then
          zip.close(zfile)
          return fail("Failed to create directory " .. dir .. ": " ..
                      (merr or "unknown"))
        end
      end

      local content, rerr = zip.read_file(zfile, filename)
      if not content then
        zip.close(zfile)
        return fail("Failed to read file from zip: " .. filename .. ": " ..
                    (rerr or "unknown"))
      end

      local wok, werr = fs.write_file(tmp_path .. "/" .. filename, content, "wb")
      if not wok then
        zip.close(zfile)
        return fail("Failed to write file " .. filename .. ": " ..
                    (werr or "unknown"))
      end
    end
  end

  zip.close(zfile)

  -- metadata.json must exist and parse
  local metadata_content = fs.read_file(tmp_path .. "/metadata.json")
  if not metadata_content then
    return fail("Extracted package does not contain metadata.json")
  end
  local mok, metadata = pcall(cjson.decode, metadata_content)
  if not mok or type(metadata) ~= "table" then
    return fail("Extracted package has an invalid metadata.json")
  end

  -- Integrity verification (section 6/6a): reject on checksum or
  -- signature mismatch
  local verified, reason = security.verify(tmp_path, fs,
    self.hash_fn or default_hash_fn(), self.crypto or default_crypto())
  if not verified then
    return fail(reason or "Integrity check failed")
  end

  -- Atomically move into place
  if fs.dir_exists(final_path) then
    local rok, rerr = self:remove_tree(final_path)
    if not rok then
      self:remove_tree(tmp_path)
      return nil, "Failed to replace previous extraction: " ..
             (rerr or "unknown")
    end
  end

  local rnok, rnerr = fs.rename(tmp_path, final_path)
  if not rnok then
    self:remove_tree(tmp_path)
    return nil, "Failed to finalize extraction: " .. (rnerr or "unknown")
  end

  return final_path
end

-- Backwards-compatible alias
_M.extract_package = _M.extract

return _M
