-- Capsium Lua Library
-- security.json parsing, SHA-256 integrity verification and RSA-SHA256
-- digital signature verification
-- (ARCHITECTURE.md sections 6 and 6a; framework-agnostic, IO via injected
-- adapters)
--
-- Coverage rules (aligned with the Ruby gem): integrity checksums cover
-- EVERY package file except security.json itself and the signature file
-- (signature.sig by default) — the signature signs the checksum-covered
-- payload, so it cannot be part of it. The embedded public key PEM IS
-- covered by the checksums.

local cjson = require "cjson"

local _M = {
  _VERSION = "0.4.0"
}

-- Default package-relative signature file name (per the standard)
local DEFAULT_SIGNATURE_FILE = "signature.sig"

-- Parse a decoded security.json table into a normalized security record:
-- {
--   algorithm = "SHA-256",
--   checksums = { ["content/index.html"] = "<hex>" },
--   digital_signatures = { public_key = "signature.pub.pem",
--                          signature_file = "signature.sig" } | nil
-- }
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

  local digital_signatures
  local sigs = raw.security.digitalSignatures
  if type(sigs) == "table" then
    digital_signatures = {
      public_key = sigs.publicKey,
      signature_file = sigs.signatureFile or DEFAULT_SIGNATURE_FILE
    }
  end

  return {
    algorithm = checks.checksumAlgorithm or "SHA-256",
    checksums = checksums,
    digital_signatures = digital_signatures
  }
end

-- Recursively collect package-relative file paths under a directory,
-- using fs_adapter primitives. security.json itself is excluded, and so
-- is every dotfile/dot-directory (.htpasswd, .capsium-tombstones, ...):
-- they are never checksum-covered (the reference packager's Dir.glob
-- skips them), so they must not trip the unlisted-file check either.
local function collect_files(fs, root, prefix, out)
  out = out or {}
  local entries = fs.list_dir(root)
  if not entries then
    return out
  end

  for _, entry in ipairs(entries) do
    if entry ~= "." and entry ~= ".." and entry:sub(1, 1) ~= "." then
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

-- Build the canonical signed payload (ARCHITECTURE.md section 6a): the
-- concatenation, in sorted package-relative path order, of the bytes of
-- every file covered by the integrity checksums.
-- Returns payload | nil, err.
local function build_signed_payload(extract_path, fs, checksums)
  local paths = {}
  for path in pairs(checksums) do
    table.insert(paths, path)
  end
  table.sort(paths)

  local chunks = {}
  for _, path in ipairs(paths) do
    local content, err = fs.read_file(extract_path .. "/" .. path, "rb")
    if not content then
      return nil, "Cannot build signed payload: unreadable file: " .. path ..
                  ": " .. tostring(err)
    end
    table.insert(chunks, content)
  end

  return table.concat(chunks)
end

-- Verify the declared digital signature of an extracted package.
--   security_record: the parsed record from _M.parse
--   crypto:          capsium.crypto (or compatible) module
-- Returns true | nil, reason.
function _M.verify_signature(extract_path, fs, security_record, crypto)
  local sigs = security_record.digital_signatures
  if not sigs then
    return true
  end

  if type(sigs.public_key) ~= "string" then
    return nil, "Digital signature declared but digitalSignatures.publicKey " ..
                "is missing"
  end

  if not crypto or not crypto.available() then
    return nil, "Digital signature verification requires a crypto backend " ..
                "(lua-resty-openssl), which is unavailable"
  end

  local public_pem, kerr = fs.read_file(
    extract_path .. "/" .. sigs.public_key, "rb")
  if not public_pem then
    return nil, "Digital signature verification failed: cannot read " ..
                "public key " .. sigs.public_key .. ": " .. tostring(kerr)
  end

  local signature, serr = fs.read_file(
    extract_path .. "/" .. sigs.signature_file, "rb")
  if not signature then
    return nil, "Digital signature verification failed: cannot read " ..
                "signature file " .. sigs.signature_file .. ": " ..
                tostring(serr)
  end

  local payload, perr = build_signed_payload(extract_path, fs,
                                             security_record.checksums)
  if not payload then
    return nil, perr
  end

  local ok, verr = crypto.rsa_sha256_verify(public_pem, payload, signature)
  if ok == nil then
    return nil, "Digital signature verification failed: " .. tostring(verr)
  end
  if not ok then
    return nil, "Digital signature does not match the package contents"
  end

  return true
end

-- Verify the integrity of an extracted package directory.
--   extract_path: directory containing the extracted package
--   fs:           fs_adapter (file_exists, dir_exists, list_dir, read_file)
--   hash_fn:      function(file_path) -> sha256 hex | nil, err
--   crypto:       (optional) capsium.crypto module; required when
--                 security.json declares digitalSignatures
--
-- Returns:
--   true, nil          when security.json is absent (nothing to verify)
--   true               when checksums (and any declared signature) match
--   nil, reason        on any mismatch, missing/unlisted file, or bad input
function _M.verify(extract_path, fs, hash_fn, crypto)
  local security_path = extract_path .. "/security.json"

  if not fs.file_exists(security_path) then
    return true, nil
  end

  local content, err = fs.read_file(security_path)
  if not content then
    return nil, "Failed to read security.json: " .. tostring(err)
  end

  local ok, raw = pcall(cjson.decode, content)
  if not ok then
    return nil, "Failed to parse security.json: " .. tostring(raw)
  end

  local security_record, perr = _M.parse(raw)
  if not security_record then
    return nil, perr
  end

  if security_record.algorithm ~= "SHA-256" then
    return nil, "Unsupported checksumAlgorithm: " ..
           tostring(security_record.algorithm)
  end

  -- Every listed file must exist and match its checksum.
  for path, expected in pairs(security_record.checksums) do
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

  -- Every file in the package (except security.json and the signature
  -- file) must be listed.
  local signature_file = security_record.digital_signatures
                         and security_record.digital_signatures.signature_file
  local present = collect_files(fs, extract_path, nil, nil)
  present["security.json"] = nil
  present[DEFAULT_SIGNATURE_FILE] = nil
  if signature_file then
    present[signature_file] = nil
  end

  for rel in pairs(present) do
    if security_record.checksums[rel] == nil then
      return nil, "Integrity check failed: unlisted file: " .. rel
    end
  end

  -- Digital signature gate (section 6a): verify when declared, reject on
  -- mismatch — same gate as checksums.
  return _M.verify_signature(extract_path, fs, security_record, crypto)
end

return _M
