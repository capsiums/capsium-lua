-- Capsium Lua Library
-- Signed session values (ARCHITECTURE.md section 4b: "Session via signed
-- cookie")
--
-- A session value is base64url(json) .. "." .. base64url(hmac-sha256),
-- signed with a deploy-time secret (never from the package). Stateless:
-- nothing is stored server-side, so any nginx worker can verify.
-- Framework-agnostic; the caller supplies secret, clock and payload.

local cjson = require "cjson"

local utils = require "capsium.utils"

local _M = {
  _VERSION = "0.3.0"
}

-- ---------------------------------------------------------------------------
-- base64url (RFC 4648 section 5, no padding)
-- ---------------------------------------------------------------------------

function _M.base64url_encode(data)
  return (utils.base64_encode(data):gsub("%+", "-"):gsub("/", "_")
          :gsub("=+$", ""))
end

function _M.base64url_decode(data)
  if type(data) ~= "string" then
    return nil
  end
  local b64 = data:gsub("-", "+"):gsub("_", "/")
  local pad = #b64 % 4
  if pad == 2 then
    b64 = b64 .. "=="
  elseif pad == 3 then
    b64 = b64 .. "="
  elseif pad == 1 then
    return nil
  end
  return utils.base64_decode(b64)
end

-- ---------------------------------------------------------------------------
-- HMAC-SHA256
-- ---------------------------------------------------------------------------

local function hmac_sha256(secret, data)
  require "resty.openssl.version" -- loads libcrypto globally when needed
  local hmac = require "resty.openssl.hmac"

  local ctx = assert(hmac.new(secret, "sha256"))
  ctx:update(data)
  return ctx:final()
end

-- ---------------------------------------------------------------------------
-- Sign / verify
-- ---------------------------------------------------------------------------

-- Sign a payload table. `payload.exp` is set from ttl (seconds) and now
-- (epoch); pass ttl=nil to omit expiry.
-- Returns the session value string.
function _M.sign(payload, secret, ttl, now)
  local body = {}
  for k, v in pairs(payload) do
    body[k] = v
  end
  if ttl then
    body.exp = (now or os.time()) + ttl
  end

  local json = cjson.encode(body)
  local encoded = _M.base64url_encode(json)
  local signature = _M.base64url_encode(hmac_sha256(secret, encoded))
  return encoded .. "." .. signature
end

-- Verify a session value. Returns the payload table | nil (bad format,
-- bad signature, or expired at `now`).
function _M.verify(value, secret, now)
  if type(value) ~= "string" or type(secret) ~= "string" then
    return nil
  end

  local encoded, signature = value:match("^([^%.]+)%.([^%.]+)$")
  if not encoded or not signature then
    return nil
  end

  local expected = _M.base64url_encode(hmac_sha256(secret, encoded))
  if expected ~= signature then
    return nil
  end

  local json = _M.base64url_decode(encoded)
  if not json then
    return nil
  end

  local ok, payload = pcall(cjson.decode, json)
  if not ok or type(payload) ~= "table" then
    return nil
  end

  if payload.exp and (now or os.time()) >= payload.exp then
    return nil
  end

  return payload
end

return _M
