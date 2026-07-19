-- Capsium Lua Library
-- security.json parsing and SHA-256 integrity verification
-- (ARCHITECTURE.md section 6; framework-agnostic, IO via injected adapters)

local _M = {
  _VERSION = "0.2.0"
}

-- Parse a decoded security.json table into a normalized integrity record:
-- { algorithm = "SHA-256", checksums = { ["content/index.html"] = "<hex>" } }
-- Returns nil, err when the structure is unusable.
function _M.parse(raw)
  if type(raw) ~= "table" then
    return nil, "security.json is not a JSON object"
  end

  local checks = raw.security and raw.security.integrityChecks
  if type(checks) ~= "table" then
    return nil, "security.json missing security.integrityChecks"
  end

  if type(checks.checksums) ~= "table" then
    return nil, "security.json missing integrityChecks.checksums"
  end

  local checksums = {}
  for path, hex in pairs(checks.checksums) do
    if type(path) == "string" and type(hex) == "string" then
      checksums[path] = hex:lower()
    end
  end

  return {
    algorithm = checks.checksumAlgorithm or "SHA-256",
    checksums = checksums
  }
end

-- Recursively collect package-relative file paths under a directory,
-- using fs_adapter primitives. security.json itself is excluded.
local function collect_files(fs, root, prefix, out)
  out = out or {}
  local entries = fs.list_dir(root)
  if not entries then
    return out
  end

  for _, entry in ipairs(entries) do
    if entry ~= "." and entry ~= ".." then
      local path = root .. "/" .. entry
      local rel = prefix and (prefix .. "/" .. entry) or entry

      if fs.dir_exists(path) then
        collect_files(fs, path, rel, out)
      elseif fs.file_exists(path) then
        out[rel] = true
      end
    end
  end

  return out
end

-- Verify the integrity of an extracted package directory.
--   extract_path: directory containing the extracted package
--   fs:           fs_adapter (file_exists, dir_exists, list_dir, read_file)
--   hash_fn:      function(file_path) -> sha256 hex | nil, err
--
-- Returns:
--   true, nil          when security.json is absent (nothing to verify)
--   true               when every checksum matches and coverage is complete
--   nil, reason        on any mismatch, missing/unlisted file, or bad input
function _M.verify(extract_path, fs, hash_fn)
  local security_path = extract_path .. "/security.json"

  if not fs.file_exists(security_path) then
    return true, nil
  end

  local content, err = fs.read_file(security_path)
  if not content then
    return nil, "Failed to read security.json: " .. tostring(err)
  end

  local cjson = require "cjson"
  local ok, raw = pcall(cjson.decode, content)
  if not ok then
    return nil, "Failed to parse security.json: " .. tostring(raw)
  end

  local integrity, perr = _M.parse(raw)
  if not integrity then
    return nil, perr
  end

  if integrity.algorithm ~= "SHA-256" then
    return nil, "Unsupported checksumAlgorithm: " ..
           tostring(integrity.algorithm)
  end

  -- Every listed file must exist and match its checksum.
  for path, expected in pairs(integrity.checksums) do
    local file_path = extract_path .. "/" .. path
    if not fs.file_exists(file_path) then
      return nil, "Integrity check failed: missing file: " .. path
    end

    local actual, herr = hash_fn(file_path)
    if not actual then
      return nil, "Integrity check failed: cannot hash " .. path ..
             ": " .. tostring(herr)
    end

    if actual:lower() ~= expected then
      return nil, "Integrity check failed: checksum mismatch: " .. path
    end
  end

  -- Every file in the package (except security.json) must be listed.
  local present = collect_files(fs, extract_path, nil, nil)
  present["security.json"] = nil

  for rel in pairs(present) do
    if integrity.checksums[rel] == nil then
      return nil, "Integrity check failed: unlisted file: " .. rel
    end
  end

  return true
end

return _M
