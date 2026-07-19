-- capsium-lua Package Decrypter Module
-- Framework-agnostic encrypted-package support (ARCHITECTURE.md section 6b)
--
-- Encrypted .cap zip layout (per 05x-packaging):
--   metadata.json    cleartext (identification only; the inner zip's own
--                    metadata.json is what gets loaded)
--   signature.json   cleartext encryption envelope
--   package.enc      AES-256-GCM ciphertext of the inner zip
--
-- Envelope:
--   { "encryption": { "algorithm": "AES-256-GCM",
--                     "keyManagement": "RSA-OAEP-SHA256",
--                     "encryptedDek": "<base64>",
--                     "iv": "<base64 12-byte IV>",
--                     "authTag": "<base64 16-byte tag>" } }
--
-- The DEK is unwrapped with a configured RSA private key (OAEP, SHA-256,
-- MGF1-SHA256); the inner zip is then handled exactly like a plaintext
-- package (including integrity verification).

local cjson = require "cjson"

local utils = require "capsium.utils"

local _M = {
  _VERSION = "0.3.0"
}

local ENCRYPTED_FILE = "package.enc"
local ENVELOPE_FILE = "signature.json"

local ALGORITHM = "AES-256-GCM"
local KEY_MANAGEMENT = "RSA-OAEP-SHA256"

-- True when a zip file list looks like the encrypted layout.
function _M.is_encrypted_listing(files)
  if type(files) ~= "table" then
    return false
  end
  for _, name in ipairs(files) do
    if name == ENCRYPTED_FILE then
      return true
    end
  end
  return false
end

-- Parse and validate an encryption envelope JSON string.
-- Returns envelope | nil, err.
function _M.parse_envelope(json)
  local ok, raw = pcall(cjson.decode, json)
  if not ok or type(raw) ~= "table" or type(raw.encryption) ~= "table" then
    return nil, "invalid encryption envelope in " .. ENVELOPE_FILE
  end

  local envelope = raw.encryption
  if envelope.algorithm ~= ALGORITHM
     or envelope.keyManagement ~= KEY_MANAGEMENT then
    return nil, "unsupported encryption envelope: " ..
                tostring(envelope.algorithm) .. "/" ..
                tostring(envelope.keyManagement)
  end

  if type(envelope.encryptedDek) ~= "string" or type(envelope.iv) ~= "string"
     or type(envelope.authTag) ~= "string" then
    return nil, "encryption envelope missing encryptedDek/iv/authTag"
  end

  return envelope
end

-- Decrypt an encrypted package.
--   zip:              zip adapter with the encrypted package already opened
--   fs:               fs adapter
--   crypto:           capsium.crypto module
--   opts.private_key_path (required): path of the RSA private key PEM
--   opts.inner_zip_path (required): where to write the decrypted inner zip
--
-- Returns inner_zip_path | nil, err. When no private key is configured the
-- error states that clearly (the reactor maps it to a 5xx with reason).
function _M.decrypt_inner_zip(zip_handle, zip, fs, crypto, opts)
  if type(opts) ~= "table" or type(opts.private_key_path) ~= "string" then
    return nil, "Package is encrypted but no private key is configured " ..
                "(set encryption.privateKeyPath in the reactor config)"
  end

  if not crypto or not crypto.available() then
    return nil, "Package is encrypted but the crypto backend " ..
                "(lua-resty-openssl) is unavailable"
  end

  -- Envelope
  local envelope_json, eerr = zip.read_file(zip_handle, ENVELOPE_FILE)
  if not envelope_json then
    return nil, "Encrypted package is missing " .. ENVELOPE_FILE .. ": " ..
                tostring(eerr)
  end

  local envelope, perr = _M.parse_envelope(envelope_json)
  if not envelope then
    return nil, perr
  end

  -- Private key
  local private_pem, kerr = fs.read_file(opts.private_key_path, "rb")
  if not private_pem then
    return nil, "Cannot read the configured private key " ..
                opts.private_key_path .. ": " .. tostring(kerr)
  end

  -- Unwrap the DEK
  local wrapped_dek = utils.base64_decode(envelope.encryptedDek)
  if not wrapped_dek then
    return nil, "Invalid base64 in the encryption envelope (encryptedDek)"
  end

  local dek, derr = crypto.rsa_unwrap_dek(private_pem, wrapped_dek)
  if not dek then
    return nil, derr
  end

  -- Decrypt the inner zip
  local ciphertext, cerr = zip.read_file(zip_handle, ENCRYPTED_FILE)
  if not ciphertext then
    return nil, "Encrypted package is missing " .. ENCRYPTED_FILE .. ": " ..
                tostring(cerr)
  end

  local iv = utils.base64_decode(envelope.iv)
  local auth_tag = utils.base64_decode(envelope.authTag)
  if not iv or not auth_tag then
    return nil, "Invalid base64 in the encryption envelope (iv/authTag)"
  end

  local plaintext, gerr = crypto.aes_256_gcm_decrypt(dek, iv, ciphertext,
                                                     auth_tag)
  if not plaintext then
    return nil, gerr
  end

  local wok, werr2 = fs.write_file(opts.inner_zip_path, plaintext, "wb")
  if not wok then
    return nil, "Failed to write decrypted package: " .. tostring(werr2)
  end

  return opts.inner_zip_path
end

return _M
