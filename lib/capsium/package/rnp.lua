-- OpenPGP signature verification via FFI to librnp (CC 62001 §05x-security,
-- m-signatures). The Ruby reactor uses the `rnp` gem over librnp; this
-- module gives the Lua reactor the same capability via LuaJIT FFI.
--
-- Detection: `local ok, rnp = pcall(ffi.load, "rnp")`. When librnp is
-- not installed, `available()` returns false and the reactor falls back
-- to the RSA-SHA256 / X.509 path (which is always available via
-- lua-resty-openssl). When librnp IS installed, the reactor can verify
-- OpenPGP detached signatures produced by the Ruby reactor's OpenPgpSigner.
--
-- Install: `brew install rnp` (macOS) or `apt install librnp-dev`
-- (Debian/Ubuntu). The shared library is `librnp-0` (Homebrew) or
-- `librnp` (Linux).

-- Detect LuaJIT FFI. The module gracefully degrades when FFI is
-- unavailable (standard Lua 5.x in tests): available() returns false,
-- is_openpgp_key still works (pure string detection), and
-- verify_detached returns nil + a clear message.
local has_ffi, ffi = pcall(require, "ffi")
local M = {}

-- Only declare C types when FFI is available (LuaJIT / OpenResty).
if has_ffi then
  ffi.cdef[[
    typedef struct rnp_ffi_st *rnp_ffi_t;
    typedef struct rnp_input_st *rnp_input_t;
    typedef struct rnp_op_verify_st *rnp_op_verify_t;
    typedef struct rnp_op_verify_signature_st *rnp_op_verify_signature_t;
    typedef struct rnp_key_handle_st *rnp_key_handle_t;

    int rnp_library_init(void);
    int rnp_ffi_create(rnp_ffi_t *ffi, const char *pub_format, const char *sec_format);
    void rnp_ffi_destroy(rnp_ffi_t ffi);
    int rnp_load_keys(rnp_ffi_t ffi, const char *format,
                      rnp_input_t input, unsigned int flags);
    int rnp_input_from_memory(rnp_input_t *input, const void *buf,
                              size_t buf_len, _Bool copy);
    void rnp_input_destroy(rnp_input_t input);
    int rnp_op_verify_create(rnp_op_verify_t *op, rnp_ffi_t ffi,
                             rnp_input_t input, rnp_input_t signature);
    int rnp_op_verify_execute(rnp_op_verify_t op);
    size_t rnp_op_verify_get_signature_count(rnp_op_verify_t op);
    int rnp_op_verify_get_signature_at(rnp_op_verify_t op, size_t idx,
                                       rnp_op_verify_signature_t *sig);
    int rnp_op_verify_signature_get_status(rnp_op_verify_signature_t sig);
    void rnp_op_verify_destroy(rnp_op_verify_t op);
  ]]
end

-- Load the shared library. Try common names across platforms.
-- Guarded: skipped entirely when FFI is unavailable.
local rnp_lib = nil
local load_errors = {}

if has_ffi then
  for _, name in ipairs({ "rnp-0", "rnp", "librnp-0", "librnp" }) do
    local ok, lib = pcall(ffi.load, name)
    if ok then
      rnp_lib = lib
      break
    end
    load_errors[#load_errors + 1] = name .. ": " .. tostring(lib)
  end
else
  load_errors[#load_errors + 1] = "LuaJIT FFI not available"
end

-- Whether librnp was successfully loaded.
function M.available()
  return rnp_lib ~= nil
end

-- Human-readable explanation when not available (for error messages).
function M.missing_reason()
  return "librnp not found (tried: " .. table.concat(load_errors, "; ") ..
         "). Install with: brew install rnp (macOS) or apt install librnp-dev (Linux)."
end

-- Detect whether a public key is OpenPGP format (vs X.509 PEM).
-- OpenPGP armored keys start with "-----BEGIN PGP PUBLIC KEY BLOCK-----"
-- (or binary OpenPGP packets with specific magic bytes 0x99/0x95).
-- X.509 PEM starts with "-----BEGIN CERTIFICATE-----" or
-- "-----BEGIN PUBLIC KEY-----".
function M.is_openpgp_key(key_data)
  if type(key_data) ~= "string" then return false end
  if key_data:find("BEGIN PGP", 1, true) then return true end
  -- Binary OpenPGP public key packet: old-format packet tag 0x99 (pubkey)
  -- or 0x95 (public subkey). Not a reliable heuristic for all formats
  -- but catches the common cases.
  local byte = key_data:byte(1)
  return byte == 0x99 or byte == 0x95
end

-- Verify an OpenPGP detached signature over `data` using a public key.
--   data:      the signed payload (string of bytes)
--   signature: the detached OpenPGP signature (string of bytes)
--   public_key: the OpenPGP public key (armored or binary)
-- Returns: true | nil, error_string
function M.verify_detached(data, signature, public_key)
  if not rnp_lib then
    return nil, M.missing_reason()
  end

  -- Initialize the library (once per process is fine, but calling
  -- multiple times is safe per the librnp docs).
  local rc = rnp_lib.rnp_library_init()
  if rc ~= 0 then
    return nil, "rnp_library_init failed: " .. tostring(rc)
  end

  -- Create the FFI instance (GPG = OpenPGP format).
  local ffi_handle = ffi.new("rnp_ffi_t[1]")
  rc = rnp_lib.rnp_ffi_create(ffi_handle, "GPG", "GPG")
  if rc ~= 0 then
    return nil, "rnp_ffi_create failed: " .. tostring(rc)
  end

  local ok, err = pcall(function()
    -- Load the public key into the keyring.
    local key_input = ffi.new("rnp_input_t[1]")
    rc = rnp_lib.rnp_input_from_memory(key_input, public_key, #public_key, true)
    if rc ~= 0 then error("rnp_input_from_memory (key) failed: " .. tostring(rc)) end
    rc = rnp_lib.rnp_load_keys(ffi_handle[0], "GPG", key_input[0], 0)
    rnp_lib.rnp_input_destroy(key_input[0])
    if rc ~= 0 then error("rnp_load_keys failed: " .. tostring(rc)) end

    -- Create inputs for data + signature.
    local data_input = ffi.new("rnp_input_t[1]")
    rc = rnp_lib.rnp_input_from_memory(data_input, data, #data, true)
    if rc ~= 0 then error("rnp_input_from_memory (data) failed: " .. tostring(rc)) end

    local sig_input = ffi.new("rnp_input_t[1]")
    rc = rnp_lib.rnp_input_from_memory(sig_input, signature, #signature, true)
    if rc ~= 0 then
      rnp_lib.rnp_input_destroy(data_input[0])
      error("rnp_input_from_memory (sig) failed: " .. tostring(rc))
    end

    -- Create and execute the verify operation.
    local op = ffi.new("rnp_op_verify_t[1]")
    rc = rnp_lib.rnp_op_verify_create(op, ffi_handle[0], data_input[0], sig_input[0])
    if rc ~= 0 then
      rnp_lib.rnp_input_destroy(data_input[0])
      rnp_lib.rnp_input_destroy(sig_input[0])
      error("rnp_op_verify_create failed: " .. tostring(rc))
    end

    rc = rnp_lib.rnp_op_verify_execute(op[0])

    -- Check signature results regardless of execute rc — the execute
    -- may return non-zero when a signature doesn't verify, which is
    -- a valid "verification failed" result (not a system error).
    local count = rnp_lib.rnp_op_verify_get_signature_count(op[0])
    local verified = false
    if count > 0 then
      local sig = ffi.new("rnp_op_verify_signature_t[1]")
      rnp_lib.rnp_op_verify_get_signature_at(op[0], 0, sig)
      -- RNP_SUCCESS = 0 means the signature verified.
      verified = rnp_lib.rnp_op_verify_signature_get_status(sig[0]) == 0
    end

    -- Cleanup.
    rnp_lib.rnp_op_verify_destroy(op[0])
    rnp_lib.rnp_input_destroy(data_input[0])
    rnp_lib.rnp_input_destroy(sig_input[0])

    if not verified then
      error("OpenPGP signature verification failed (status: " .. tostring(rc) ..
            ", signatures: " .. tostring(count) .. ")")
    end
  end)

  -- Always destroy the FFI handle.
  rnp_lib.rnp_ffi_destroy(ffi_handle[0])

  if not ok then
    return nil, tostring(err)
  end
  return true
end

return M
