-- Capsium Lua Library
-- SHA-256 hash adapter (framework-agnostic)
--
-- Backend selection (open/closed: inject a custom hash function where the
-- auto-detected backends do not fit):
--   1. lua-resty-string (resty.sha256) when running inside OpenResty
--   2. Built-in pure-Lua SHA-256 core (works on Lua 5.1 with a bit library,
--      Lua 5.2 via bit32, Lua 5.3/5.4 via native operators, LuaJIT)

local _M = {
  _VERSION = "0.4.0"
}

local MOD = 4294967296 -- 2^32

-- ---------------------------------------------------------------------------
-- Pure-Lua SHA-256 core
-- ---------------------------------------------------------------------------

-- First 32 bits of the fractional parts of the cube roots of the first
-- 64 prime numbers.
local K = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

-- Resolve 32-bit bitwise operations for the running Lua implementation.
local function resolve_ops()
  -- LuaJIT / luabitop
  local ok, bit = pcall(require, "bit")
  if ok and type(bit) == "table" and bit.band then
    return {
      band = bit.band,
      bxor = bit.bxor,
      bnot = bit.bnot,
      rshift = bit.rshift,
      rrotate = bit.ror
    }, "bit"
  end

  -- Lua 5.2 global bit32
  local bit32 = rawget(_G, "bit32")
  if type(bit32) == "table" and bit32.band then
    return {
      band = bit32.band,
      bxor = bit32.bxor,
      bnot = bit32.bnot,
      rshift = bit32.rshift,
      rrotate = bit32.rrotate
    }, "bit32"
  end

  -- Lua 5.3/5.4 native bitwise operators
  local loader = load([[
    return {
      band = function(a, b) return a & b end,
      bxor = function(a, b, c)
        if c == nil then return a ~ b end
        return (a ~ b) ~ c
      end,
      bnot = function(a) return (~a) & 0xFFFFFFFF end,
      rshift = function(a, n) return (a >> n) & 0xFFFFFFFF end,
      rrotate = function(a, n)
        return ((a >> n) | (a << (32 - n))) & 0xFFFFFFFF
      end
    }
  ]])
  if loader then
    local ok2, ops = pcall(loader)
    if ok2 and type(ops) == "table" then
      return ops, "native"
    end
  end

  return nil, nil
end

local pure_ops, pure_ops_name = resolve_ops()

local function u32be(n)
  return string.char(
    math.floor(n / 16777216) % 256,
    math.floor(n / 65536) % 256,
    math.floor(n / 256) % 256,
    n % 256)
end

-- Compute SHA-256 of a binary string using the resolved bitwise ops.
-- Returns lowercase hex digest.
local function sha256_pure(msg)
  local band = pure_ops.band
  local bxor = pure_ops.bxor
  local bnot = pure_ops.bnot
  local rshift = pure_ops.rshift
  local rrotate = pure_ops.rrotate

  -- Pre-processing: pad the message to a multiple of 64 bytes.
  local len = #msg
  local zero_pad = (56 - (len + 1)) % 64
  local len_hi = math.floor(len / 536870912) -- 2^29
  local len_lo = (len * 8) % MOD
  local padded = msg .. "\128" .. string.rep("\0", zero_pad) ..
                 u32be(len_hi) .. u32be(len_lo)

  -- Initial hash values: first 32 bits of the fractional parts of the
  -- square roots of the first 8 prime numbers.
  local h0 = 0x6a09e667
  local h1 = 0xbb67ae85
  local h2 = 0x3c6ef372
  local h3 = 0xa54ff53a
  local h4 = 0x510e527f
  local h5 = 0x9b05688c
  local h6 = 0x1f83d9ab
  local h7 = 0x5be0cd19

  local w = {}

  for block = 1, #padded, 64 do
    -- Prepare the message schedule.
    for t = 0, 15 do
      local i = block + t * 4
      local b1, b2, b3, b4 = padded:byte(i, i + 3)
      w[t] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    end
    for t = 16, 63 do
      local x = w[t - 15]
      local s0 = bxor(bxor(rrotate(x, 7), rrotate(x, 18)), rshift(x, 3))
      local y = w[t - 2]
      local s1 = bxor(bxor(rrotate(y, 17), rrotate(y, 19)), rshift(y, 10))
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) % MOD
    end

    local a, b, c, d = h0, h1, h2, h3
    local e, f, g, h = h4, h5, h6, h7

    for t = 0, 63 do
      local s1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = (h + s1 + ch + K[t + 1] + w[t]) % MOD
      local s0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local temp2 = (s0 + maj) % MOD

      h = g
      g = f
      f = e
      e = (d + temp1) % MOD
      d = c
      c = b
      b = a
      a = (temp1 + temp2) % MOD
    end

    h0 = (h0 + a) % MOD
    h1 = (h1 + b) % MOD
    h2 = (h2 + c) % MOD
    h3 = (h3 + d) % MOD
    h4 = (h4 + e) % MOD
    h5 = (h5 + f) % MOD
    h6 = (h6 + g) % MOD
    h7 = (h7 + h) % MOD
  end

  return string.format("%08x%08x%08x%08x%08x%08x%08x%08x",
    h0 % MOD, h1 % MOD, h2 % MOD, h3 % MOD,
    h4 % MOD, h5 % MOD, h6 % MOD, h7 % MOD)
end

-- ---------------------------------------------------------------------------
-- Backend detection
-- ---------------------------------------------------------------------------

local resty_sha256, resty_string
do
  local ok1, mod1 = pcall(require, "resty.sha256")
  local ok2, mod2 = pcall(require, "resty.string")
  if ok1 and ok2 and type(mod1) == "table" and type(mod2) == "table"
     and mod1.new and mod2.to_hex then
    -- The module loads fine outside nginx (e.g. under busted) but its
    -- FFI symbols only resolve inside an OpenResty worker — probe it.
    local usable = pcall(function()
      local ctx = mod1:new()
      ctx:update("probe")
      mod2.to_hex(ctx:final())
    end)
    if usable then
      resty_sha256 = mod1
      resty_string = mod2
    end
  end
end

-- Name of the active backend ("resty" or "pure-lua:<ops>"), mainly for
-- diagnostics and tests.
function _M.backend()
  if resty_sha256 then
    return "resty"
  end
  if pure_ops then
    return "pure-lua:" .. pure_ops_name
  end
  return "none"
end

-- SHA-256 hex digest of a binary string.
function _M.sha256_hex(data)
  if resty_sha256 then
    local ctx = resty_sha256:new()
    ctx:update(data)
    return resty_string.to_hex(ctx:final())
  end

  if not pure_ops then
    error("No SHA-256 backend available " ..
          "(need resty.sha256, LuaJIT bit, luabitop, bit32 or Lua 5.3+)")
  end

  return sha256_pure(data)
end

-- SHA-256 hex digest of a file's contents.
function _M.sha256_file_hex(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, "Failed to open file: " .. tostring(err)
  end

  local content = f:read("*all")
  f:close()

  if not content then
    return nil, "Failed to read file: " .. tostring(path)
  end

  return _M.sha256_hex(content)
end

return _M
