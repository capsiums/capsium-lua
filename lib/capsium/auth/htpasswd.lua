-- Capsium Lua Library
-- htpasswd file verification (ARCHITECTURE.md section 4b)
--
-- Supports the formats the platform's native tooling produces:
--   $apr1$...   Apache MD5 (htpasswd -m; implemented in pure Lua)
--   {SHA}...    base64 SHA-1 (htpasswd -s)
--   $2y$/$2b$/$2a$, $1$, $5$, $6$ and traditional DES — via the system
--   crypt(3) (musl on the pinned OpenResty image supports all of these,
--   matching what nginx auth_basic_user_file accepts there)
--
-- IO-free and framework-agnostic: the caller supplies the htpasswd file
-- content. The crypt(3) formats need LuaJIT's ffi (OpenResty, busted on
-- LuaJIT); the module still loads without it, those formats just report
-- no-match.

local ok_ffi, ffi = pcall(require, "ffi")

local utils = require "capsium.utils"

local _M = {
  _VERSION = "0.4.0"
}

if ok_ffi then
  ffi.cdef[[
    char *crypt(const char *key, const char *salt);
  ]]
end

-- ---------------------------------------------------------------------------
-- Digest helpers (resty.openssl, loaded like capsium.crypto)
-- ---------------------------------------------------------------------------

local digest_mod

local function raw_digest(algo, data)
  if not digest_mod then
    require "resty.openssl.version" -- loads libcrypto globally when needed
    digest_mod = require "resty.openssl.digest"
  end

  local ctx = assert(digest_mod.new(algo))
  ctx:update(data)
  return ctx:final()
end

-- ---------------------------------------------------------------------------
-- apr1 (Apache MD5) — the htpasswd default
-- ---------------------------------------------------------------------------

local ITOA64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

-- apr1's custom base64: big-endian 24-bit groups, emitted LSB-first,
-- n chars per group (mirrors Apache apr_md5.c)
local function apr1_b64(b0, b1, b2, n)
  local v = b0 * 65536 + b1 * 256 + b2
  local out = {}
  for _ = 1, n do
    out[#out + 1] = ITOA64:sub(v % 64 + 1, v % 64 + 1)
    v = math.floor(v / 64)
  end
  return table.concat(out)
end

-- Compute the apr1 hash of `password` for the given salt.
local function apr1_hash(password, salt)
  salt = salt:sub(1, 8)

  local ctx = password .. "$apr1$" .. salt
  local final = raw_digest("md5", password .. salt .. password)

  for pl = #password, 1, -16 do
    ctx = ctx .. final:sub(1, math.min(16, pl))
  end

  local i = #password
  while i > 0 do
    if i % 2 == 1 then
      ctx = ctx .. "\0"
    else
      ctx = ctx .. password:sub(1, 1)
    end
    i = math.floor(i / 2)
  end

  final = raw_digest("md5", ctx)

  for round = 0, 999 do
    local step = {}
    if round % 2 == 1 then
      step[#step + 1] = password
    else
      step[#step + 1] = final
    end
    if round % 3 ~= 0 then
      step[#step + 1] = salt
    end
    if round % 7 ~= 0 then
      step[#step + 1] = password
    end
    if round % 2 == 1 then
      step[#step + 1] = final
    else
      step[#step + 1] = password
    end
    final = raw_digest("md5", table.concat(step))
  end

  local b = { final:byte(1, 16) }
  return "$apr1$" .. salt .. "$" ..
         apr1_b64(b[1], b[7], b[13], 4) ..
         apr1_b64(b[2], b[8], b[14], 4) ..
         apr1_b64(b[3], b[9], b[15], 4) ..
         apr1_b64(b[4], b[10], b[16], 4) ..
         apr1_b64(b[5], b[11], b[6], 4) ..
         apr1_b64(0, 0, b[12], 2)
end

-- ---------------------------------------------------------------------------
-- Verification
-- ---------------------------------------------------------------------------

-- Constant-time string comparison.
local function secure_equals(a, b)
  if #a ~= #b then
    return false
  end
  local diff = 0
  for i = 1, #a do
    diff = diff + (a:byte(i) ~= b:byte(i) and 1 or 0)
  end
  return diff == 0
end

-- Verify a password against one htpasswd hash string.
function _M.verify_hash(password, stored)
  if type(stored) ~= "string" or stored == "" then
    return false
  end

  -- apr1 (Apache MD5)
  local salt = stored:match("^%$apr1%$([^$]+)%$")
  if salt then
    return secure_equals(apr1_hash(password, salt), stored)
  end

  -- {SHA} base64 SHA-1
  local sha_b64 = stored:match("^{SHA}(.+)$")
  if sha_b64 then
    local digest = raw_digest("sha1", password)
    return secure_equals(utils.base64_encode(digest), sha_b64)
  end

  -- crypt(3) family: $2y$/$2b$/$2a$ (bcrypt), $1$ (md5), $5$ (sha256),
  -- $6$ (sha512); anything else is tried as traditional DES (salt is the
  -- first two characters). Needs LuaJIT's ffi.
  if not ok_ffi then
    return false
  end

  local ok, result = pcall(function()
    local computed = ffi.C.crypt(password, stored)
    if computed == nil then
      return nil
    end
    return ffi.string(computed)
  end)
  if not ok or not result then
    return false
  end

  return secure_equals(result, stored)
end

-- Verify username/password against htpasswd file content.
-- Lines are `user:hash`; blank lines and comments (#) are ignored.
-- Returns true | false.
function _M.verify(content, username, password)
  if type(content) ~= "string" or type(username) ~= "string"
     or type(password) ~= "string" then
    return false
  end

  for line in content:gmatch("[^\r\n]+") do
    local user, hash = line:match("^([^:]+):(.*)$")
    if user == username then
      return _M.verify_hash(password, hash)
    end
  end

  return false
end

return _M
