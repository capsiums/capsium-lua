describe("Capsium Package model", function()
  local Package = require "capsium.package.package"
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

  -- Build a security.json string covering every file in the mock tree.
  local function build_security(fs, prefix)
    local checksums = {}

    local function scan(dir, rel_prefix)
      for _, entry in ipairs(fs:list_dir(dir) or {}) do
        local path = dir .. "/" .. entry
        local rel = rel_prefix == "" and entry or rel_prefix .. "/" .. entry
        if fs:dir_exists(path) then
          scan(path, rel)
        else
          checksums[rel] = hash.sha256_hex(fs:read_file(path))
        end
      end
    end
    scan(prefix, "")

    return cjson.encode({
      security = {
        integrityChecks = {
          checksumAlgorithm = "SHA-256",
          checksums = checksums
        }
      }
    })
  end

  describe("legacy package", function()
    local fs = MockFs.new({
      ["/pkg/metadata.json"] =
        '{"name":"legacy-pkg","version":"0.1.0","author":"A","dependencies":' ..
        '[{"name":"capsium://example.com/dep-a","version":">=1.0"}]}',
      ["/pkg/manifest.json"] =
        '{"content":[{"file":"index.html","mime":"text/html"},' ..
        '{"file":"styles.css","mime":"text/css"}]}',
      ["/pkg/routes.json"] =
        '{"routes":[{"path":"/","target":{"file":"index.html"}},' ..
        '{"path":"/styles.css","target":{"file":"styles.css"}}]}',
      ["/pkg/storage.json"] =
        '{"datasets":[{"name":"animals","source":"data/animals.json",' ..
        '"format":"json"}]}',
      ["/pkg/content/index.html"] = "<h1>legacy</h1>",
      ["/pkg/content/styles.css"] = "body{}",
      ["/pkg/data/animals.json"] = '[{"name":"cat"}]'
    })

    local package = Package.new("/pkg", { fs_adapter = fs })
    assert.is_true(package:load())

    it("parses metadata and normalizes legacy dependencies", function()
      local metadata = package:get_metadata()
      assert.equals("legacy-pkg", metadata.name)
      assert.equals("0.1.0", metadata.version)
      assert.are_same({ ["capsium://example.com/dep-a"] = ">=1.0" },
                      metadata.dependencies)
    end)

    it("normalizes the legacy manifest", function()
      local manifest = package:get_manifest()
      assert.equals("text/html", manifest["content/index.html"].type)
      assert.equals("text/css", manifest["content/styles.css"].type)
    end)

    it("normalizes legacy routes to canonical resources", function()
      local routes = package:get_routes()
      assert.equals("content/index.html", routes[1].resource)
      assert.equals("content/styles.css", routes[2].resource)
    end)

    it("normalizes the legacy storage", function()
      local storage = package:get_storage()
      assert.equals("data/animals.json", storage.animals.source)
    end)

    it("resolves static routes", function()
      local target = package:resolve("/")
      assert.equals("static", target.kind)
      assert.equals("/pkg/content/index.html", target.path)
      assert.equals("text/html", target.mime)
    end)

    it("loads a JSON dataset", function()
      local data, format = package:get_dataset("animals")
      assert.equals("json", format)
      assert.equals("cat", data[1].name)
    end)

    it("computes the identifier", function()
      assert.equals("legacy-pkg-0.1.0", package:get_identifier())
    end)
  end)

  describe("canonical package without routes.json", function()
    local fs = MockFs.new({
      ["/cpkg/metadata.json"] =
        '{"name":"canon-pkg","version":"1.0.0","dependencies":{}}',
      ["/cpkg/manifest.json"] =
        '{"resources":{' ..
        '"content/index.html":{"type":"text/html"},' ..
        '"content/about.html":{"type":"text/html"},' ..
        '"content/app.js":{"type":"text/javascript"}}}',
      ["/cpkg/storage.json"] =
        '{"storage":{"dataSets":{"animals":{"source":"data/animals.json"}}}}',
      ["/cpkg/content/index.html"] = "<h1>canonical</h1>",
      ["/cpkg/content/about.html"] = "<h1>about</h1>",
      ["/cpkg/content/app.js"] = "console.log(1)",
      ["/cpkg/data/animals.json"] = '[{"name":"dog"}]'
    })

    local package = Package.new("/cpkg", { fs_adapter = fs })
    assert.is_true(package:load())

    it("auto-generates routes from the manifest (dual HTML + index)",
       function()
      local routes = package:get_routes()
      local by_path = {}
      for _, route in ipairs(routes) do
        by_path[route.path] = route
      end

      assert.equals("content/index.html", by_path["/"].resource)
      assert.equals("content/index.html", by_path["/index"].resource)
      assert.equals("content/index.html", by_path["/index.html"].resource)
      assert.equals("content/about.html", by_path["/about"].resource)
      assert.equals("content/about.html", by_path["/about.html"].resource)
      assert.equals("content/app.js", by_path["/app.js"].resource)
      assert.equals("animals", by_path["/api/v1/data/animals"].dataset)
    end)

    it("resolves the index with the manifest MIME type", function()
      local target = package:resolve("/")
      assert.equals("text/html", target.mime)

      local js = package:resolve("/app.js")
      assert.equals("text/javascript", js.mime)
    end)

    it("resolves dataset routes", function()
      local target = package:resolve("/api/v1/data/animals")
      assert.equals("dataset", target.kind)
      assert.equals("animals", target.dataset)
    end)

    it("returns nil, err for unknown routes", function()
      local target, err = package:resolve("/nope")
      assert.is_nil(target)
      assert.is_string(err)
    end)
  end)

  describe("package without manifest.json", function()
    local fs = MockFs.new({
      ["/mpkg/metadata.json"] = '{"name":"m","version":"1.0.0"}',
      ["/mpkg/content/index.html"] = "<h1>x</h1>",
      ["/mpkg/content/assets/app.js"] = "x"
    })

    it("auto-generates the manifest by scanning content/", function()
      local package = Package.new("/mpkg", { fs_adapter = fs })
      assert.is_true(package:load())

      local manifest = package:get_manifest()
      assert.equals("text/html", manifest["content/index.html"].type)
      assert.equals("text/javascript",
                    manifest["content/assets/app.js"].type)

      local target = package:resolve("/")
      assert.equals("/mpkg/content/index.html", target.path)
    end)
  end)

  describe("invalid packages", function()
    it("rejects missing metadata.json", function()
      local fs = MockFs.new({})
      local package = Package.new("/empty", { fs_adapter = fs })
      local ok, err = package:load()
      assert.is_falsy(ok)
      assert.is_truthy(tostring(err):find("metadata"))
    end)

    it("rejects invalid metadata.json", function()
      local fs = MockFs.new({
        ["/bad/metadata.json"] = "{not json"
      })
      local package = Package.new("/bad", { fs_adapter = fs })
      local ok, err = package:load()
      assert.is_falsy(ok)
      assert.is_string(err)
    end)

    it("rejects metadata without name/version", function()
      local fs = MockFs.new({
        ["/nn/metadata.json"] = '{"description":"x"}'
      })
      local package = Package.new("/nn", { fs_adapter = fs })
      local ok, err = package:load()
      assert.is_falsy(ok)
      assert.is_truthy(tostring(err):find("name"))
    end)
  end)

  describe("dataset loading", function()
    local fs = MockFs.new({
      ["/dpkg/metadata.json"] = '{"name":"d","version":"1.0.0"}',
      ["/dpkg/storage.json"] = '{"storage":{"dataSets":{' ..
        '"json_ds":{"source":"data/a.json"},' ..
        '"csv_ds":{"source":"data/b.csv"},' ..
        '"yaml_ds":{"source":"data/c.yaml"},' ..
        '"sqlite_ds":{"databaseFile":"data/d.db","table":"t"}}}}',
      ["/dpkg/data/a.json"] = '{"ok":true}',
      ["/dpkg/data/b.csv"] = "name,legs\ncat,4\n",
      ["/dpkg/data/c.yaml"] = "animals:\n" ..
        "  - name: \"Lion\"\n    legs: 4\n" ..
        "  - name: \"Eagle\"\n    legs: 2\n"
    })
    local package = Package.new("/dpkg", { fs_adapter = fs })
    assert.is_true(package:load())

    it("loads JSON datasets", function()
      local data, format = package:get_dataset("json_ds")
      assert.equals("json", format)
      assert.is_true(data.ok)
    end)

    it("loads CSV datasets as objects", function()
      local data, format = package:get_dataset("csv_ds")
      assert.equals("csv", format)
      assert.equals("cat", data[1].name)
      assert.equals("4", data[1].legs)
    end)

    it("loads YAML datasets (block-style subset)", function()
      local data, format = package:get_dataset("yaml_ds")
      assert.equals("yaml", format)
      assert.equals("Lion", data.animals[1].name)
      assert.equals(4, data.animals[1].legs)
      assert.equals("Eagle", data.animals[2].name)
    end)

    it("rejects SQLite datasets (not supported by this reactor)", function()
      local data, err = package:get_dataset("sqlite_ds")
      assert.is_nil(data)
      assert.is_truthy(tostring(err):find("SQLite"))
    end)

    it("rejects unknown datasets", function()
      local data, err = package:get_dataset("nope")
      assert.is_nil(data)
      assert.is_truthy(tostring(err):find("Unknown dataset"))
    end)
  end)

  describe("integrity verification (ARCHITECTURE.md §6)", function()
    local function secured_package()
      local fs = MockFs.new({
        ["/spkg/metadata.json"] = '{"name":"s","version":"1.0.0"}',
        ["/spkg/content/index.html"] = "<h1>secure</h1>"
      })
      fs:write_file("/spkg/security.json", build_security(fs, "/spkg"))
      return fs
    end

    it("accepts a package with matching checksums", function()
      local fs = secured_package()
      local package = Package.new("/spkg", {
        fs_adapter = fs,
        hash_fn = mock_hash_fn(fs)
      })

      local valid, reason = package:verify_integrity()
      assert.is_true(valid)
      assert.is_nil(reason)
    end)

    it("rejects on checksum mismatch", function()
      local fs = secured_package()
      fs:write_file("/spkg/content/index.html", "<h1>tampered</h1>")

      local package = Package.new("/spkg", {
        fs_adapter = fs,
        hash_fn = mock_hash_fn(fs)
      })

      local valid, reason = package:verify_integrity()
      assert.is_false(valid)
      assert.is_truthy(reason:find("checksum mismatch"))
    end)

    it("rejects on a missing listed file", function()
      local fs = secured_package()
      fs:remove("/spkg/content/index.html")

      local package = Package.new("/spkg", {
        fs_adapter = fs,
        hash_fn = mock_hash_fn(fs)
      })

      local valid, reason = package:verify_integrity()
      assert.is_false(valid)
      assert.is_truthy(reason:find("missing file"))
    end)

    it("rejects on an unlisted file", function()
      local fs = secured_package()
      fs:write_file("/spkg/content/evil.js", "alert(1)")

      local package = Package.new("/spkg", {
        fs_adapter = fs,
        hash_fn = mock_hash_fn(fs)
      })

      local valid, reason = package:verify_integrity()
      assert.is_false(valid)
      assert.is_truthy(reason:find("unlisted file"))
    end)

    it("rejects an unsupported checksum algorithm", function()
      local fs = MockFs.new({
        ["/apkg/metadata.json"] = '{"name":"a","version":"1.0.0"}',
        ["/apkg/security.json"] =
          '{"security":{"integrityChecks":{' ..
          '"checksumAlgorithm":"MD5","checksums":{}}}}'
      })

      local package = Package.new("/apkg", {
        fs_adapter = fs,
        hash_fn = mock_hash_fn(fs)
      })

      local valid, reason = package:verify_integrity()
      assert.is_false(valid)
      assert.is_truthy(reason:find("Unsupported"))
    end)

    it("reports packages without security.json as valid (unverified)",
       function()
      local fs = MockFs.new({
        ["/upkg/metadata.json"] = '{"name":"u","version":"1.0.0"}'
      })

      local package = Package.new("/upkg", {
        fs_adapter = fs,
        hash_fn = mock_hash_fn(fs)
      })

      local valid = package:verify_integrity()
      assert.is_true(valid)
      assert.is_false(package:has_security())
    end)

    it("reports signed state from the declared digitalSignatures", function()
      local unsigned_fs = secured_package()
      local unsigned = Package.new("/spkg", {
        fs_adapter = unsigned_fs,
        hash_fn = mock_hash_fn(unsigned_fs)
      })
      assert.is_false(unsigned:is_signed())
      assert.is_nil(unsigned:verify_signature())

      -- Declared but unverifiable signature (bogus public key): signed,
      -- but signatureValid is false
      local fs = secured_package()
      local record = cjson.decode(fs:read_file("/spkg/security.json"))
      record.security.digitalSignatures = {
        publicKey = "signature.pub.pem",
        signatureFile = "signature.sig"
      }
      fs:write_file("/spkg/security.json", cjson.encode(record))
      fs:write_file("/spkg/signature.pub.pem", "not a pem")
      fs:write_file("/spkg/signature.sig", "not a signature")

      local signed = Package.new("/spkg", {
        fs_adapter = fs,
        hash_fn = mock_hash_fn(fs)
      })
      assert.is_true(signed:is_signed())
      assert.is_false(signed:verify_signature())
    end)
  end)
end)
