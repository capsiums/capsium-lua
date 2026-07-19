describe("Capsium package extractor", function()
  local Extractor = require "capsium.package.extractor"
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

  local function security_json_for(files)
    local checksums = {}
    for _, entry in ipairs(files) do
      if not entry.name:match("/$") then
        checksums[entry.name] = hash.sha256_hex(entry.content)
      end
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

  local simple_files = {
    { name = "metadata.json", content = '{"name":"t","version":"1.0.0"}' },
    { name = "content/", content = "" },
    { name = "content/index.html", content = "<h1>t</h1>" }
  }

  describe("successful extraction", function()
    it("extracts all files and finalizes atomically", function()
      local fs = MockFs.new({
        ["/packages/t-1.0.0.cap"] = "blob"
      })
      local zip = MockZip.new({
        ["/packages/t-1.0.0.cap"] = { files = simple_files }
      })
      local extractor = Extractor.new({
        fs_adapter = fs,
        zip_adapter = zip,
        hash_fn = mock_hash_fn(fs)
      })

      local path, err = extractor:extract("/packages/t-1.0.0.cap",
                                          "/extracted")
      assert.is_nil(err)
      assert.equals("/extracted/t-1.0.0", path)

      -- Files are at the final path, no temporary directory remains
      assert.equals('{"name":"t","version":"1.0.0"}',
                    fs:read_file("/extracted/t-1.0.0/metadata.json"))
      assert.equals("<h1>t</h1>",
                    fs:read_file("/extracted/t-1.0.0/content/index.html"))
      assert.is_false(fs:dir_exists("/extracted/.tmp-t-1.0.0"))
    end)

    it("short-circuits when already extracted and up to date", function()
      local fs = MockFs.new({
        ["/packages/t-1.0.0.cap"] = "blob"
      })
      local zip = MockZip.new({
        ["/packages/t-1.0.0.cap"] = { files = simple_files }
      })
      local extractor = Extractor.new({
        fs_adapter = fs,
        zip_adapter = zip,
        hash_fn = mock_hash_fn(fs)
      })

      local first = extractor:extract("/packages/t-1.0.0.cap", "/extracted")
      assert.equals("/extracted/t-1.0.0", first)

      -- Break the zip: the second call must NOT touch it
      zip.archives["/packages/t-1.0.0.cap"].fail_open = true
      local second, err = extractor:extract("/packages/t-1.0.0.cap",
                                            "/extracted")
      assert.is_nil(err)
      assert.equals("/extracted/t-1.0.0", second)
    end)
  end)

  describe("failure modes", function()
    local function new_extractor(files, zip_opts)
      local fs = MockFs.new({
        ["/packages/t-1.0.0.cap"] = "blob"
      })
      local archive = { files = files }
      for k, v in pairs(zip_opts or {}) do
        archive[k] = v
      end
      local zip = MockZip.new({
        ["/packages/t-1.0.0.cap"] = archive
      })
      local extractor = Extractor.new({
        fs_adapter = fs,
        zip_adapter = zip,
        hash_fn = mock_hash_fn(fs)
      })
      return extractor, fs
    end

    it("rejects a corrupt zip and leaves nothing behind", function()
      local extractor, fs = new_extractor(nil, { fail_open = true })

      local path, err = extractor:extract("/packages/t-1.0.0.cap",
                                          "/extracted")
      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("zip"))
      assert.is_false(fs:dir_exists("/extracted/t-1.0.0"))
      assert.is_false(fs:dir_exists("/extracted/.tmp-t-1.0.0"))
    end)

    it("rejects an archive without metadata.json", function()
      local extractor, fs = new_extractor({
        { name = "content/index.html", content = "x" }
      })

      local path, err = extractor:extract("/packages/t-1.0.0.cap",
                                          "/extracted")
      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("metadata.json"))
      assert.is_false(fs:dir_exists("/extracted/t-1.0.0"))
    end)

    it("rejects an archive with invalid metadata.json", function()
      local extractor, fs = new_extractor({
        { name = "metadata.json", content = "{not json" }
      })

      local path, err = extractor:extract("/packages/t-1.0.0.cap",
                                          "/extracted")
      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("invalid metadata.json"))
      assert.is_false(fs:dir_exists("/extracted/t-1.0.0"))
    end)

    it("rejects zip-slip paths", function()
      local extractor, fs = new_extractor({
        { name = "metadata.json", content = '{"name":"t","version":"1"}' },
        { name = "../evil.txt", content = "x" }
      })

      local path, err = extractor:extract("/packages/t-1.0.0.cap",
                                          "/extracted")
      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("unsafe path"))
      assert.is_false(fs:file_exists("/extracted/evil.txt"))
    end)

    it("rejects on security.json checksum mismatch", function()
      local files = {
        { name = "metadata.json", content = '{"name":"t","version":"1"}' },
        { name = "content/index.html", content = "<h1>t</h1>" }
      }
      local security = security_json_for(files)
      -- Tamper after checksum computation
      files[2].content = "<h1>TAMPERED</h1>"
      table.insert(files, { name = "security.json", content = security })

      local extractor, fs = new_extractor(files)

      local path, err = extractor:extract("/packages/t-1.0.0.cap",
                                          "/extracted")
      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("checksum mismatch"))
      assert.is_false(fs:dir_exists("/extracted/t-1.0.0"))
      assert.is_false(fs:dir_exists("/extracted/.tmp-t-1.0.0"))
    end)

    it("accepts a package with valid security.json checksums", function()
      local files = {
        { name = "metadata.json", content = '{"name":"t","version":"1"}' },
        { name = "content/index.html", content = "<h1>t</h1>" }
      }
      table.insert(files,
                   { name = "security.json",
                     content = security_json_for(files) })

      local extractor, fs = new_extractor(files)

      local path, err = extractor:extract("/packages/t-1.0.0.cap",
                                          "/extracted")
      assert.is_nil(err)
      assert.equals("/extracted/t-1.0.0", path)
      assert.is_true(fs:file_exists("/extracted/t-1.0.0/security.json"))
    end)

    it("rejects invalid package filenames", function()
      local fs = MockFs.new({})
      local zip = MockZip.new({})
      local extractor = Extractor.new({
        fs_adapter = fs,
        zip_adapter = zip
      })

      local path, err = extractor:extract("/packages/t.zip", "/extracted")
      assert.is_nil(path)
      assert.is_truthy(tostring(err):find("%.cap"))
    end)
  end)
end)
