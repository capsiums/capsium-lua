describe("Capsium reactor core", function()
  local Reactor = require "capsium.reactor"
  local MockFs = require "mock_fs"
  local MockZip = require "mock_zip"
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

  -- Build a reactor with two packages: one good, one with a bad checksum.
  local function build_reactor()
    local good_files = {
      { name = "metadata.json",
        content = '{"name":"good-pkg","version":"1.0.0","author":"A",' ..
                  '"description":"good"}' },
      { name = "content/index.html", content = "<h1>good</h1>" }
    }
    local good_checksums = {}
    for _, entry in ipairs(good_files) do
      good_checksums[entry.name] = hash.sha256_hex(entry.content)
    end
    table.insert(good_files, {
      name = "security.json",
      content = cjson.encode({
        security = {
          integrityChecks = {
            checksumAlgorithm = "SHA-256",
            checksums = good_checksums
          }
        }
      })
    })

    local bad_files = {
      { name = "metadata.json",
        content = '{"name":"bad-pkg","version":"1.0.0"}' },
      { name = "content/index.html", content = "<h1>TAMPERED</h1>" },
      { name = "security.json",
        content = cjson.encode({
          security = {
            integrityChecks = {
              checksumAlgorithm = "SHA-256",
              checksums = {
                ["metadata.json"] = hash.sha256_hex(
                  '{"name":"bad-pkg","version":"1.0.0"}'),
                ["content/index.html"] = string.rep("0", 64)
              }
            }
          }
        })
      }
    }

    local fs = MockFs.new({
      ["/packages/good-pkg-1.0.0.cap"] = "good-blob",
      ["/packages/bad-pkg-1.0.0.cap"] = "bad-blob"
    })
    local zip = MockZip.new({
      ["/packages/good-pkg-1.0.0.cap"] = { files = good_files },
      ["/packages/bad-pkg-1.0.0.cap"] = { files = bad_files }
    })

    local reactor = Reactor.new({
      package_dir = "/packages",
      extract_dir = "/extracted",
      fs_adapter = fs,
      zip_adapter = zip,
      hash_fn = mock_hash_fn(fs)
    })

    return reactor, fs
  end

  it("lists packages sorted by name", function()
    local reactor = build_reactor()
    local packages = reactor:list_packages()

    assert.equals(2, #packages)
    assert.equals("bad-pkg-1.0.0", packages[1].name)
    assert.equals("good-pkg-1.0.0", packages[2].name)
  end)

  it("lazily extracts and loads packages on demand", function()
    local reactor, fs = build_reactor()

    -- Nothing extracted yet (cold reactor)
    assert.is_false(fs:dir_exists("/extracted/good-pkg-1.0.0"))

    local package, err = reactor:get_package("good-pkg-1.0.0")
    assert.is_nil(err)
    assert.is_not_nil(package)
    assert.is_true(fs:dir_exists("/extracted/good-pkg-1.0.0"))
    assert.equals("good-pkg", package:get_metadata().name)
  end)

  it("returns not_found for unknown packages", function()
    local reactor = build_reactor()
    local package, _, status = reactor:get_package("nope-1.0.0")

    assert.is_nil(package)
    assert.equals("not_found", status)
  end)

  it("rejects a tampered package with an error", function()
    local reactor = build_reactor()
    local package, err, status = reactor:get_package("bad-pkg-1.0.0")

    assert.is_nil(package)
    assert.equals("error", status)
    assert.is_truthy(tostring(err):find("checksum mismatch"))
  end)

  describe("introspection reports (cold start)", function()
    it("reports metadata for loadable packages without prior requests",
       function()
      local reactor = build_reactor()
      local report = reactor:metadata_report()

      assert.equals(1, #report.packages)
      assert.equals("good-pkg", report.packages[1].name)
      assert.equals("1.0.0", report.packages[1].version)
      assert.equals("A", report.packages[1].author)
      assert.equals("good", report.packages[1].description)
    end)

    it("reports routes per package", function()
      local reactor = build_reactor()
      local report = reactor:routes_report()

      assert.equals(1, #report.routes)
      assert.equals("good-pkg-1.0.0", report.routes[1].package)
      assert.is_true(#report.routes[1].routes > 0)
      assert.equals("GET", report.routes[1].routes[1].method)
    end)

    it("reports SHA-256 content hashes of the .cap blobs", function()
      local reactor = build_reactor()
      local report = reactor:content_hashes_report()

      assert.equals(2, #report.contentHashes)
      for _, entry in ipairs(report.contentHashes) do
        assert.equals(64, #entry.hash)
        assert.is_truthy(entry.hash:match("^[0-9a-f]+$"))
      end
    end)

    it("reports actual content validity", function()
      local reactor = build_reactor()
      local report = reactor:content_validity_report()

      assert.equals(2, #report.contentValidity)

      local by_name = {}
      for _, entry in ipairs(report.contentValidity) do
        by_name[entry.package] = entry
        assert.is_string(entry.lastChecked)
        assert.is_false(entry.encrypted)
      end

      -- Loadable packages are keyed by their metadata name; failed
      -- packages fall back to the .cap filename
      local good = by_name["good-pkg"]
      assert.is_true(good.valid)
      assert.is_nil(good.reason)
      assert.is_false(good.signed)
      assert.is_nil(good.signatureValid)

      local bad = by_name["bad-pkg-1.0.0"]
      assert.is_false(bad.valid)
      assert.is_truthy(bad.reason:find("checksum mismatch"))
      assert.is_nil(bad.signed)
    end)

    it("reports encrypted packages that cannot be decrypted", function()
      local fs = MockFs.new({
        ["/packages/enc-pkg-1.0.0.cap"] = "enc-blob"
      })
      local zip = MockZip.new({
        ["/packages/enc-pkg-1.0.0.cap"] = {
          files = {
            { name = "metadata.json",
              content = '{"name":"enc-pkg","version":"1.0.0"}' },
            { name = "signature.json", content = "{}" },
            { name = "package.enc", content = "ciphertext" }
          }
        }
      })
      local reactor = Reactor.new({
        package_dir = "/packages",
        extract_dir = "/extracted",
        fs_adapter = fs,
        zip_adapter = zip,
        hash_fn = mock_hash_fn(fs)
      })

      local report = reactor:content_validity_report()
      assert.equals(1, #report.contentValidity)

      local entry = report.contentValidity[1]
      assert.equals("enc-pkg-1.0.0", entry.package)
      assert.is_false(entry.valid)
      assert.is_truthy(entry.reason:find("no private key"))
      assert.is_true(entry.encrypted)
      assert.is_nil(entry.signed)
    end)
  end)
end)
