-- Tests for capsium.package.rnp (OpenPGP verification via librnp FFI).
-- These tests run under any Lua version (5.1-5.4 + LuaJIT). The FFI
-- path is only exercised under LuaJIT + librnp installed; the tests
-- verify graceful degradation when either is absent.

local rnp = require "capsium.package.rnp"

describe("capsium.package.rnp", function()
  describe("available", function()
    it("returns a boolean", function()
      assert.is_boolean(rnp.available())
    end)
  end)

  describe("missing_reason", function()
    it("returns a helpful message when unavailable", function()
      if not rnp.available() then
        local reason = rnp.missing_reason()
        assert.is_string(reason)
        assert.is_truthy(reason:find("librnp", 1, true) or reason:find("FFI", 1, true))
      end
    end)
  end)

  describe("is_openpgp_key", function()
    it("detects armored OpenPGP public keys", function()
      local key = "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQENBF...\n-----END PGP PUBLIC KEY BLOCK-----\n"
      assert.is_true(rnp.is_openpgp_key(key))
    end)

    it("rejects X.509 PEM certificates", function()
      local cert = "-----BEGIN CERTIFICATE-----\nMIID...\n-----END CERTIFICATE-----\n"
      assert.is_false(rnp.is_openpgp_key(cert))
    end)

    it("rejects X.509 PEM public keys", function()
      local pem = "-----BEGIN PUBLIC KEY-----\nMIIBIjAN...\n-----END PUBLIC KEY-----\n"
      assert.is_false(rnp.is_openpgp_key(pem))
    end)

    it("rejects non-string input", function()
      assert.is_false(rnp.is_openpgp_key(nil))
      assert.is_false(rnp.is_openpgp_key(42))
      assert.is_false(rnp.is_openpgp_key({}))
    end)

    it("detects binary OpenPGP public key packets", function()
      -- Old-format packet tag 0x99 (public-key packet)
      local binary = string.char(0x99, 0x01, 0x0D, 0x04)
      assert.is_true(rnp.is_openpgp_key(binary))
    end)
  end)

  describe("verify_detached (graceful degradation)", function()
    it("returns nil + error when librnp is unavailable", function()
      if not rnp.available() then
        local ok, err = rnp.verify_detached("data", "sig", "key")
        assert.is_nil(ok)
        assert.is_string(err)
      end
    end)

    it("returns an error mentioning the missing library", function()
      if not rnp.available() then
        local _, err = rnp.verify_detached("data", "sig", "key")
        assert.is_truthy(err:find("librnp", 1, true) or err:find("FFI", 1, true))
      end
    end)
  end)
end)
