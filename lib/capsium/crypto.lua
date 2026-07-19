-- Capsium Lua Library
-- Cryptographic backend facade (framework-agnostic)
--
-- Backend: lua-resty-openssl (FFI bindings to the OpenSSL 3 libcrypto that
-- ships with the pinned OpenResty image). Chosen over the alternatives:
--   * no `openssl` binary exists in the pinned image (and `openssl enc`
--     cannot do AEAD/GCM anyway);
--   * lua-resty-rsa is not in the image and its OAEP digest handling is
--     limited; lua-resty-openssl covers RSA-SHA256 verify, RSA-OAEP-SHA256
--     unwrap and AES-256-GCM with one dependency.
--
-- Loading note: resty.openssl.version MUST be required first. Inside nginx
-- workers the OpenSSL symbols are already in the global FFI namespace
-- (nginx links libcrypto); under plain LuaJIT (busted) the version module
-- loads libcrypto/libssl into the global namespace via ffi.load — which
-- needs the libcrypto.so/libssl.so symlinks created in the Dockerfile.
-- resty.openssl.pkey alone assumes the symbols are already global.
--
-- The reactor only ever verifies signatures and decrypts packages; no
-- encryption/signing happens here (that is the packager's job).
--
-- All functions return nil, err when the backend is unavailable, so callers
-- can decide how to degrade (packages requiring crypto are rejected).

local _M = {
  _VERSION = "0.4.0"
}

-- OAEP padding constant (RSA_PKCS1_OAEP_PADDING in OpenSSL)
local RSA_PKCS1_OAEP_PADDING = 4

local pkey, cipher, digest

local function load_backend()
  if pkey then
    return true
  end

  local ok = pcall(require, "resty.openssl.version")
  if not ok then
    return false
  end

  local ok1, mod1 = pcall(require, "resty.openssl.pkey")
  local ok2, mod2 = pcall(require, "resty.openssl.cipher")
  local ok3, mod3 = pcall(require, "resty.openssl.digest")
  if not (ok1 and ok2 and ok3) then
    return false
  end

  pkey, cipher, digest = mod1, mod2, mod3
  return true
end

-- True when the crypto backend is usable in this process.
function _M.available()
  return load_backend()
end

-- Verify an RSA-SHA256 signature (ARCHITECTURE.md section 6a).
--   public_pem: PEM-encoded RSA public key (or X.509 certificate PEM)
--   payload:    the signed byte stream
--   signature:  raw RSA-SHA256 signature bytes
-- Returns true | false, err.
function _M.rsa_sha256_verify(public_pem, payload, signature)
  if not load_backend() then
    return nil, "crypto backend unavailable (lua-resty-openssl)"
  end

  if type(public_pem) ~= "string" or type(payload) ~= "string"
     or type(signature) ~= "string" then
    return nil, "invalid arguments for signature verification"
  end

  local key, kerr = pkey.new(public_pem)
  if not key then
    return nil, "cannot load public key: " .. tostring(kerr)
  end

  local ctx, derr = digest.new("sha256")
  if not ctx then
    return nil, "cannot create digest: " .. tostring(derr)
  end
  ctx:update(payload)

  local ok, verr = key:verify(signature, ctx)
  if ok == true then
    return true
  end
  -- verification failure: ok is false/nil, verr carries the OpenSSL reason
  return false, verr
end

-- Unwrap a data encryption key wrapped with RSA-OAEP-SHA256 (MGF1-SHA256)
-- (ARCHITECTURE.md section 6b).
--   private_pem:  PEM-encoded RSA private key
--   wrapped_dek:  raw wrapped-DEK bytes
-- Returns dek (32 bytes) | nil, err.
function _M.rsa_unwrap_dek(private_pem, wrapped_dek)
  if not load_backend() then
    return nil, "crypto backend unavailable (lua-resty-openssl)"
  end

  if type(private_pem) ~= "string" or type(wrapped_dek) ~= "string" then
    return nil, "invalid arguments for DEK unwrap"
  end

  local key, kerr = pkey.new(private_pem)
  if not key then
    return nil, "cannot load private key: " .. tostring(kerr)
  end

  local dek, derr = key:decrypt(wrapped_dek, RSA_PKCS1_OAEP_PADDING,
                                { oaep_md = "sha256", mgf1_md = "sha256" })
  if not dek then
    return nil, "cannot unwrap the data encryption key (wrong key?): " ..
                tostring(derr)
  end

  return dek
end

-- Decrypt AES-256-GCM ciphertext (ARCHITECTURE.md section 6b).
--   key:        32-byte DEK
--   iv:         12-byte GCM IV
--   ciphertext: raw ciphertext bytes
--   auth_tag:   16-byte GCM authentication tag
-- Returns plaintext | nil, err (authentication failures included).
function _M.aes_256_gcm_decrypt(key, iv, ciphertext, auth_tag)
  if not load_backend() then
    return nil, "crypto backend unavailable (lua-resty-openssl)"
  end

  if type(key) ~= "string" or #key ~= 32 then
    return nil, "invalid DEK (expected 32 bytes)"
  end
  if type(iv) ~= "string" or #iv ~= 12 then
    return nil, "invalid GCM IV (expected 12 bytes)"
  end
  if type(ciphertext) ~= "string" or type(auth_tag) ~= "string"
     or #auth_tag ~= 16 then
    return nil, "invalid ciphertext or GCM auth tag (expected 16 bytes)"
  end

  local c, cerr = cipher.new("aes-256-gcm")
  if not c then
    return nil, "cannot create cipher: " .. tostring(cerr)
  end

  local plaintext, perr = c:decrypt(key, iv, ciphertext, false, nil, auth_tag)
  if not plaintext then
    return nil, "decryption failed (wrong key or tampered package): " ..
                tostring(perr)
  end

  return plaintext
end

return _M
