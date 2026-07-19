describe("capsium.package.decrypter (section 6b)", function()
  local decrypter = require "capsium.package.decrypter"
  local Extractor = require "capsium.package.extractor"
  local crypto = require "capsium.crypto"
  local utils = require "capsium.utils"
  local hash = require "capsium.adapters.hash"
  local vectors = require "crypto_vectors"
  local MockFs = require "mock_fs"
  local MockZip = require "mock_zip"
  local cjson = require "cjson"

  local function envelope_json(overrides)
    local envelope = {
      algorithm = "AES-256-GCM",
      keyManagement = "RSA-OAEP-SHA256",
      encryptedDek = vectors.wrapped_dek_b64,
      iv = vectors.gcm_iv_b64,
      authTag = vectors.gcm_tag_b64
    }
    for k, v in pairs(overrides or {}) do
      envelope[k] = v
    end
    return cjson.encode({ encryption = envelope })
  end

  local function ciphertext()
    return assert(utils.base64_decode(vectors.gcm_ciphertext_b64))
  end

  local function plaintext()
    return assert(utils.base64_decode(vectors.gcm_plaintext_b64))
  end

  describe("is_encrypted_listing", function()
    it("detects the encrypted layout by package.enc", function()
      assert.is_true(decrypter.is_encrypted_listing({
        "metadata.json", "signature.json", "package.enc"
      }))
      assert.is_false(decrypter.is_encrypted_listing({
        "metadata.json", "content/index.html"
      }))
      assert.is_false(decrypter.is_encrypted_listing(nil))
    end)
  end)

  describe("parse_envelope", function()
    it("accepts the canonical envelope", function()
      local envelope = assert(decrypter.parse_envelope(envelope_json()))
      assert.equals("AES-256-GCM", envelope.algorithm)
      assert.equals("RSA-OAEP-SHA256", envelope.keyManagement)
    end)

    it("rejects unsupported algorithms", function()
      local envelope, err = decrypter.parse_envelope(envelope_json({
        algorithm = "OCB"
      }))
      assert.is_nil(envelope)
      assert.is_truthy(tostring(err):find("unsupported encryption envelope"))
    end)

    it("rejects envelopes missing fields", function()
      local envelope, err = decrypter.parse_envelope(
        '{"encryption":{"algorithm":"AES-256-GCM",' ..
        '"keyManagement":"RSA-OAEP-SHA256"}}')
      assert.is_nil(envelope)
      assert.is_truthy(tostring(err):find("missing"))
    end)

    it("rejects non-JSON input", function()
      local envelope, err = decrypter.parse_envelope("not json")
      assert.is_nil(envelope)
      assert.is_truthy(tostring(err):find("invalid encryption envelope"))
    end)
  end)

  describe("decrypt_inner_zip", function()
    if not crypto.available() then
      pending("decrypt tests skipped: crypto backend unavailable",
              function() end)
      return
    end

    local function setup(opts)
      opts = opts or {}
      local fs = MockFs.new({
        ["/keys/private.pem"] = vectors.private_pem
      })
      local zip = MockZip.new({
        ["/packages/enc.cap"] = {
          files = {
            { name = "metadata.json", content = "{}" },
            { name = "signature.json",
              content = envelope_json(opts.envelope_overrides) },
            { name = "package.enc",
              content = opts.ciphertext or ciphertext() }
          }
        }
      })
      local handle = assert(zip.open("/packages/enc.cap"))
      return fs, zip, handle
    end

    local function call_opts(overrides)
      local o = {
        private_key_path = "/keys/private.pem",
        inner_zip_path = "/tmp/inner.cap"
      }
      for k, v in pairs(overrides or {}) do
        o[k] = v
      end
      return o
    end

    it("decrypts with the configured private key", function()
      local fs, zip, handle = setup()
      local path, err = decrypter.decrypt_inner_zip(handle, zip, fs, crypto,
                                                    call_opts())

      assert.is_nil(err)
      assert.equals("/tmp/inner.cap", path)
      assert.equals(plaintext(), fs:read_file("/tmp/inner.cap"))
    end)

    it("fails clearly when no private key is configured", function()
      local fs, zip, handle = setup()
      local path, err = decrypter.decrypt_inner_zip(handle, zip, fs, crypto,
        { inner_zip_path = "/tmp/inner.cap" })

      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("no private key is configured"))
    end)

    it("fails when the private key file is unreadable", function()
      local fs, zip, handle = setup()
      local path, err = decrypter.decrypt_inner_zip(handle, zip, fs, crypto,
        call_opts({ private_key_path = "/keys/nope.pem" }))

      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("Cannot read the configured" ..
                                          " private key"))
    end)

    it("fails when the crypto backend is unavailable", function()
      local fs, zip, handle = setup()
      local no_crypto = { available = function() return false end }
      local path, err = decrypter.decrypt_inner_zip(handle, zip, fs,
                                                    no_crypto, call_opts())

      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("crypto backend"))
    end)

    it("fails on tampered ciphertext (GCM authentication)", function()
      local tampered = "X" .. ciphertext():sub(2)
      local fs, zip, handle = setup({ ciphertext = tampered })
      local path, err = decrypter.decrypt_inner_zip(handle, zip, fs, crypto,
                                                    call_opts())

      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("decryption failed"))
    end)
  end)

  describe("extractor integration (encrypted .cap -> normal extraction)",
    function()
      if not crypto.available() then
        pending("extractor decrypt tests skipped: crypto backend " ..
                "unavailable", function() end)
        return
      end

      local inner_files = {
        { name = "metadata.json",
          content = '{"name":"enc-pkg","version":"1.0.0"}' },
        { name = "content/index.html", content = "<h1>secret</h1>" }
      }

      local function inner_security()
        local checksums = {}
        for _, entry in ipairs(inner_files) do
          checksums[entry.name] = hash.sha256_hex(entry.content)
        end
        return cjson.encode({
          security = {
            integrityChecks = {
              checksumAlgorithm = "SHA-256",
              checksums = checksums
            }
          }
        })
      end

      local function build_extractor(encryption)
        local fs = MockFs.new({
          ["/packages/enc-pkg-1.0.0.cap"] = "outer blob",
          ["/keys/private.pem"] = vectors.private_pem
        })
        local inner_with_security = {}
        for _, entry in ipairs(inner_files) do
          table.insert(inner_with_security, entry)
        end
        table.insert(inner_with_security,
                     { name = "security.json", content = inner_security() })

        local zip = MockZip.new({
          ["/packages/enc-pkg-1.0.0.cap"] = {
            files = {
              { name = "metadata.json", content = "{}" },
              { name = "signature.json", content = envelope_json() },
              { name = "package.enc", content = ciphertext() }
            }
          },
          ["/extracted/.tmp-enc-pkg-1.0.0.inner.cap"] = {
            files = inner_with_security
          }
        })

        return Extractor.new({
          fs_adapter = fs,
          zip_adapter = zip,
          hash_fn = function(path)
            local content = fs:read_file(path)
            return content and hash.sha256_hex(content) or nil
          end,
          encryption = encryption
        }), fs
      end

      it("extracts an encrypted package with the configured key", function()
        local extractor, fs = build_extractor({
          private_key_path = "/keys/private.pem"
        })

        local path, err = extractor:extract("/packages/enc-pkg-1.0.0.cap",
                                            "/extracted")
        assert.is_nil(err)
        assert.equals("/extracted/enc-pkg-1.0.0", path)
        assert.is_true(fs:file_exists(
          "/extracted/enc-pkg-1.0.0/content/index.html"))
        -- the temporary inner zip is cleaned up
        assert.is_false(fs:file_exists(
          "/extracted/.tmp-enc-pkg-1.0.0.inner.cap"))
      end)

      it("rejects an encrypted package when no key is configured", function()
        local extractor = build_extractor(nil)

        local path, err = extractor:extract("/packages/enc-pkg-1.0.0.cap",
                                            "/extracted")
        assert.is_nil(path)
        assert.is_truthy(tostring(err):find("no private key is configured"))
      end)

      it("re-decrypts when the effective key changes (key identity)",
         function()
        local extractor, fs = build_extractor({
          private_key_path = "/keys/private.pem"
        })

        -- First extraction with the correct key
        local path = extractor:extract("/packages/enc-pkg-1.0.0.cap",
                                       "/extracted")
        assert.equals("/extracted/enc-pkg-1.0.0", path)

        -- Fast path: same key, package unchanged — returns the existing
        -- extraction even though the key file has vanished
        fs:remove("/keys/private.pem")
        local path2 = extractor:extract("/packages/enc-pkg-1.0.0.cap",
                                        "/extracted")
        assert.equals("/extracted/enc-pkg-1.0.0", path2)

        -- A different (now unreadable) key forces re-decryption and fails
        local path3, err3 = extractor:extract("/packages/enc-pkg-1.0.0.cap",
          "/extracted",
          { encryption = { private_key_path = "/keys/private.pem.bak" } })
        assert.is_nil(path3)
        assert.is_truthy(tostring(err3):find("Cannot read the configured" ..
                                             " private key"))

        -- The previous good extraction survived the failed re-extraction
        assert.is_true(fs:file_exists(
          "/extracted/enc-pkg-1.0.0/content/index.html"))
      end)
    end)
end)
