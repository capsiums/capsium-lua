describe("capsium.crypto (lua-resty-openssl facade)", function()
  local crypto = require "capsium.crypto"
  local utils = require "capsium.utils"
  local vectors = require "crypto_vectors"

  it("reports availability of the backend", function()
    assert.is_true(crypto.available())
  end)

  describe("rsa_sha256_verify", function()
    it("verifies a freshly signed payload and rejects tampering", function()
      require "resty.openssl.version"
      local pkey = require "resty.openssl.pkey"
      local digest = require "resty.openssl.digest"

      local key = assert(pkey.new({ type = "RSA", bits = 2048 }))
      local payload = "the quick brown fox"
      local d = digest.new("sha256")
      d:update(payload)
      local sig = assert(key:sign(d))

      local pub_pem = key:tostring("public")
      assert.is_true(crypto.rsa_sha256_verify(pub_pem, payload, sig))

      local ok = crypto.rsa_sha256_verify(pub_pem, payload .. "x", sig)
      assert.is_false(ok)
    end)

    it("rejects a signature made with a different key", function()
      require "resty.openssl.version"
      local pkey = require "resty.openssl.pkey"
      local digest = require "resty.openssl.digest"

      local signer = assert(pkey.new({ type = "RSA", bits = 2048 }))
      local other = assert(pkey.new({ type = "RSA", bits = 2048 }))
      local d = digest.new("sha256")
      d:update("payload")
      local sig = assert(signer:sign(d))

      local ok = crypto.rsa_sha256_verify(other:tostring("public"),
                                          "payload", sig)
      assert.is_false(ok)
    end)

    it("errors on an unloadable public key", function()
      local ok, err = crypto.rsa_sha256_verify("not a pem", "payload", "sig")
      assert.is_falsy(ok)
      assert.is_truthy(tostring(err):find("public key"))
    end)
  end)

  describe("rsa_unwrap_dek (RSA-OAEP-SHA256)", function()
    it("unwraps a DEK wrapped by Ruby OpenSSL (cross-implementation)",
       function()
      local wrapped = assert(utils.base64_decode(vectors.wrapped_dek_b64))
      assert.equals(256, #wrapped)

      local dek, err = crypto.rsa_unwrap_dek(vectors.private_pem, wrapped)
      assert.is_nil(err)
      assert.is_not_nil(dek)
      assert.equals(32, #dek)
      assert.equals(assert(utils.base64_decode(vectors.dek_b64)), dek)
    end)

    it("fails to unwrap with the wrong private key", function()
      require "resty.openssl.version"
      local pkey = require "resty.openssl.pkey"
      local other = assert(pkey.new({ type = "RSA", bits = 2048 }))

      local wrapped = assert(utils.base64_decode(vectors.wrapped_dek_b64))
      local dek, err = crypto.rsa_unwrap_dek(other:tostring("private"),
                                             wrapped)
      assert.is_nil(dek)
      assert.is_truthy(tostring(err):find("unwrap"))
    end)
  end)

  describe("aes_256_gcm_decrypt", function()
    it("decrypts Ruby-encrypted ciphertext (cross-implementation)", function()
      local dek = assert(utils.base64_decode(vectors.dek_b64))
      local iv = assert(utils.base64_decode(vectors.gcm_iv_b64))
      local tag = assert(utils.base64_decode(vectors.gcm_tag_b64))
      local ct = assert(utils.base64_decode(vectors.gcm_ciphertext_b64))

      local pt, err = crypto.aes_256_gcm_decrypt(dek, iv, ct, tag)
      assert.is_nil(err)
      assert.equals(assert(utils.base64_decode(vectors.gcm_plaintext_b64)),
                    pt)
    end)

    it("rejects a wrong key", function()
      local iv = assert(utils.base64_decode(vectors.gcm_iv_b64))
      local tag = assert(utils.base64_decode(vectors.gcm_tag_b64))
      local ct = assert(utils.base64_decode(vectors.gcm_ciphertext_b64))

      local pt, err = crypto.aes_256_gcm_decrypt(string.rep("z", 32),
                                                 iv, ct, tag)
      assert.is_nil(pt)
      assert.is_truthy(tostring(err):find("decryption failed"))
    end)

    it("rejects a tampered auth tag", function()
      local dek = assert(utils.base64_decode(vectors.dek_b64))
      local iv = assert(utils.base64_decode(vectors.gcm_iv_b64))
      local tag = assert(utils.base64_decode(vectors.gcm_tag_b64))
      local ct = assert(utils.base64_decode(vectors.gcm_ciphertext_b64))
      local bad_tag = tag:sub(1, 15) ..
                      (tag:sub(16, 16) == "a" and "b" or "a")

      local pt = crypto.aes_256_gcm_decrypt(dek, iv, ct, bad_tag)
      assert.is_nil(pt)
    end)

    it("validates key/iv/tag sizes", function()
      local pt, err = crypto.aes_256_gcm_decrypt("short", "123456789012",
                                                 "ct", "1234567890123456")
      assert.is_nil(pt)
      assert.is_truthy(tostring(err):find("32 bytes"))
    end)
  end)
end)
