describe("capsium.package.security", function()
  local security = require "capsium.package.security"
  local crypto = require "capsium.crypto"
  local MockFs = require "mock_fs"
  local hash = require "capsium.adapters.hash"
  local cjson = require "cjson"

  local function mock_hash_fn(fs)
    return function(path)
      local content = fs:read_file(path)
      if not content then
        return nil, "no such file"
      end
      return hash.sha256_hex(content)
    end
  end

  -- Sign payloads with a fresh test key (RSA-SHA256 sign works fine in
  -- lua-resty-openssl; only OAEP *encryption* is out of scope here).
  local function generate_key()
    require "resty.openssl.version"
    local pkey = require "resty.openssl.pkey"
    return assert(pkey.new({ type = "RSA", bits = 2048 }))
  end

  local function sign_payload(key, payload)
    require "resty.openssl.version"
    local digest = require "resty.openssl.digest"
    local d = digest.new("sha256")
    d:update(payload)
    return assert(key:sign(d))
  end

  -- Build a signed mock package tree (files table + security.json +
  -- signature.pub.pem + signature.sig), mirroring the Ruby Signer:
  -- checksums cover every file except security.json and signature.sig;
  -- the payload is the concatenation of covered file bytes in sorted
  -- path order.
  local function build_signed_tree(key, opts)
    opts = opts or {}
    local files = opts.files or {
      ["metadata.json"] = '{"name":"signed-pkg","version":"1.0.0"}',
      ["content/index.html"] = "<h1>signed</h1>"
    }
    local tree = {}
    for path, content in pairs(files) do
      tree["/pkg/" .. path] = content
    end
    tree["/pkg/signature.pub.pem"] = key:tostring("public")

    local checksums = {}
    for path, content in pairs(tree) do
      local rel = path:sub(6) -- strip /pkg/
      if rel ~= "security.json" then
        checksums[rel] = hash.sha256_hex(content)
      end
    end

    tree["/pkg/security.json"] = cjson.encode({
      security = {
        integrityChecks = {
          checksumAlgorithm = "SHA-256",
          checksums = checksums
        },
        digitalSignatures = {
          publicKey = "signature.pub.pem",
          signatureFile = "signature.sig"
        }
      }
    })

    local paths = {}
    for rel in pairs(checksums) do
      table.insert(paths, rel)
    end
    table.sort(paths)
    local chunks = {}
    for _, rel in ipairs(paths) do
      table.insert(chunks, tree["/pkg/" .. rel])
    end
    local payload = table.concat(chunks)

    local signature = opts.bad_signature
                      and sign_payload(key, "a different payload")
                       or sign_payload(key, payload)
    tree["/pkg/signature.sig"] = signature

    return tree, payload, signature
  end

  describe("parse", function()
    it("extracts the digitalSignatures block", function()
      local record = assert(security.parse({
        security = {
          integrityChecks = { checksums = { ["a"] = string.rep("0", 64) } },
          digitalSignatures = {
            publicKey = "keys/public.pem",
            signatureFile = "custom.sig"
          }
        }
      }))

      assert.is_not_nil(record.digital_signatures)
      assert.equals("keys/public.pem", record.digital_signatures.public_key)
      assert.equals("custom.sig", record.digital_signatures.signature_file)
    end)

    it("defaults the signature file name to signature.sig", function()
      local record = assert(security.parse({
        security = {
          integrityChecks = { checksums = {} },
          digitalSignatures = { publicKey = "keys/public.pem" }
        }
      }))

      assert.equals("signature.sig",
                    record.digital_signatures.signature_file)
    end)

    it("has no digital_signatures when undeclared", function()
      local record = assert(security.parse({
        security = { integrityChecks = { checksums = {} } }
      }))

      assert.is_nil(record.digital_signatures)
    end)
  end)

  describe("verify with digital signatures (section 6a)", function()
    if not crypto.available() then
      pending("signature tests skipped: crypto backend unavailable",
              function() end)
      return
    end

    it("accepts a correctly signed package", function()
      local key = generate_key()
      local tree = build_signed_tree(key)
      local fs = MockFs.new(tree)

      local ok, reason = security.verify("/pkg", fs, mock_hash_fn(fs),
                                         crypto)
      assert.is_true(ok)
      assert.is_nil(reason)
    end)

    it("rejects a package whose signature does not match", function()
      local key = generate_key()
      local tree = build_signed_tree(key, { bad_signature = true })
      local fs = MockFs.new(tree)

      local ok, reason = security.verify("/pkg", fs, mock_hash_fn(fs),
                                         crypto)
      assert.is_falsy(ok)
      assert.is_truthy(tostring(reason):find("[Ss]ignature"))
    end)

    it("rejects when the signature file is missing", function()
      local key = generate_key()
      local tree = build_signed_tree(key)
      tree["/pkg/signature.sig"] = nil
      local fs = MockFs.new(tree)

      local ok, reason = security.verify("/pkg", fs, mock_hash_fn(fs),
                                         crypto)
      assert.is_falsy(ok)
      assert.is_truthy(tostring(reason):find("signature file"))
    end)

    it("rejects when the public key file is missing", function()
      local key = generate_key()
      local tree = build_signed_tree(key)
      -- Remove the key file AND its checksum entry so the checksum gate
      -- passes and the signature gate hits the unreadable key
      local sec = cjson.decode(tree["/pkg/security.json"])
      sec.security.integrityChecks.checksums["signature.pub.pem"] = nil
      tree["/pkg/security.json"] = cjson.encode(sec)
      tree["/pkg/signature.pub.pem"] = nil
      local fs = MockFs.new(tree)

      local ok, reason = security.verify("/pkg", fs, mock_hash_fn(fs),
                                         crypto)
      assert.is_falsy(ok)
      assert.is_truthy(tostring(reason):find("public key"))
    end)

    it("rejects when the crypto backend is unavailable", function()
      local key = generate_key()
      local tree = build_signed_tree(key)
      local fs = MockFs.new(tree)

      local no_crypto = {
        available = function() return false end
      }
      local ok, reason = security.verify("/pkg", fs, mock_hash_fn(fs),
                                         no_crypto)
      assert.is_falsy(ok)
      assert.is_truthy(tostring(reason):find("crypto backend"))
    end)

    it("tolerates an unlisted signature.sig in coverage checks", function()
      local key = generate_key()
      local tree = build_signed_tree(key)
      local fs = MockFs.new(tree)

      -- signature.sig is present but intentionally NOT in the checksums;
      -- coverage must not flag it as an unlisted file
      local ok, reason = security.verify("/pkg", fs, mock_hash_fn(fs),
                                         crypto)
      assert.is_true(ok)
      assert.is_nil(reason)
    end)

    it("flags an embedded public key missing from the checksums", function()
      local key = generate_key()
      local tree = build_signed_tree(key)

      -- Remove signature.pub.pem from the checksum coverage: the embedded
      -- key IS part of the signed payload and must stay covered
      local sec = cjson.decode(tree["/pkg/security.json"])
      sec.security.integrityChecks.checksums["signature.pub.pem"] = nil
      tree["/pkg/security.json"] = cjson.encode(sec)
      local fs = MockFs.new(tree)

      local ok, reason = security.verify("/pkg", fs, mock_hash_fn(fs),
                                         crypto)
      assert.is_falsy(ok)
      assert.is_truthy(tostring(reason):find("unlisted file"))
    end)
  end)

  describe("verify without signatures (unchanged behavior)", function()
    it("passes a checksummed package with no digitalSignatures", function()
      local files = {
        ["/pkg/metadata.json"] = '{"name":"plain","version":"1.0.0"}',
        ["/pkg/content/index.html"] = "<h1>plain</h1>"
      }
      local checksums = {}
      for path, content in pairs(files) do
        checksums[path:sub(6)] = hash.sha256_hex(content)
      end
      files["/pkg/security.json"] = cjson.encode({
        security = {
          integrityChecks = {
            checksumAlgorithm = "SHA-256",
            checksums = checksums
          }
        }
      })

      local fs = MockFs.new(files)
      local ok, reason = security.verify("/pkg", fs, mock_hash_fn(fs))
      assert.is_true(ok)
      assert.is_nil(reason)
    end)
  end)
end)
