describe("static package registry (registry pull)", function()
  local Registry = require "capsium.registry"
  local MockFs = require "mock_fs"
  local hash = require "capsium.adapters.hash"
  local cjson = require "cjson"

  local GUID = "capsium://fixtures/registry-app"

  -- A local registry tree: index.json plus .cap "bytes" (plain strings;
  -- the registry only hashes and copies them).
  local function build_fs(opts)
    opts = opts or {}
    local cap100 = opts.cap100 or "cap-bytes-1.0.0"
    local cap110 = opts.cap110 or "cap-bytes-1.1.0"

    local index = {
      packages = {
        [GUID] = {
          name = "registry-app",
          versions = {
            ["1.0.0"] = {
              file = "registry-app-1.0.0.cap",
              sha256 = hash.sha256_hex(cap100),
              size = #cap100
            },
            ["1.1.0"] = {
              file = "registry-app-1.1.0.cap",
              sha256 = hash.sha256_hex(cap110),
              size = #cap110
            }
          }
        }
      }
    }

    local tree = {
      ["/registry/index.json"] = cjson.encode(index),
      ["/registry/registry-app-1.0.0.cap"] = cap100,
      ["/registry/registry-app-1.1.0.cap"] = cap110
    }
    return MockFs.new(tree)
  end

  local function new_registry(fs, extra)
    local opts = {
      ref = "/registry",
      fs_adapter = fs,
      -- Hash through the mock fs (the default hash_fn hits the real fs)
      hash_fn = function(path)
        local content = fs.read_file(path)
        if not content then
          return nil, "no such file"
        end
        return hash.sha256_hex(content)
      end
    }
    for k, v in pairs(extra or {}) do
      opts[k] = v
    end
    return Registry.new(opts)
  end

  describe("Registry.new", function()
    it("requires a reference", function()
      local registry, err, etype = Registry.new({ fs_adapter = build_fs() })
      assert.is_nil(registry)
      assert.equals("not_configured", etype)
      assert.matches("no registry configured", err)

      local empty, _, empty_type = Registry.new({
        ref = "", fs_adapter = build_fs()
      })
      assert.is_nil(empty)
      assert.equals("not_configured", empty_type)
    end)

    it("rejects a registry path that is not a directory", function()
      local fs = MockFs.new({ ["/registry"] = "x" })
      local registry, err, etype = Registry.new({
        ref = "/registry", fs_adapter = fs
      })
      assert.is_nil(registry)
      assert.equals("invalid", etype)
      assert.matches("not a directory", err)
    end)

    it("rejects plain http for non-loopback hosts", function()
      local registry, err, etype = Registry.new({
        ref = "http://example.com/registry",
        fs_adapter = build_fs(),
        http_get = function() return nil, "unreachable" end
      })
      assert.is_nil(registry)
      assert.equals("invalid", etype)
      assert.matches("must use https", err)
    end)

    it("accepts plain http for loopback hosts", function()
      for _, ref in ipairs({
        "http://127.0.0.1:8864/registry",
        "http://localhost/registry",
        "http://test.localhost/registry",
        "http://[::1]/registry"
      }) do
        local registry = assert(Registry.new({
          ref = ref,
          fs_adapter = build_fs(),
          http_get = function() return nil, "unreachable" end
        }))
        assert.is_true(registry.remote)
      end
    end)

    it("accepts https for any host and strips trailing slashes", function()
      local registry = assert(Registry.new({
        ref = "https://registry.example.com/capsium/",
        fs_adapter = build_fs(),
        http_get = function() return nil, "unreachable" end
      }))
      assert.is_true(registry.remote)
      assert.equals("https://registry.example.com/capsium", registry.ref)
    end)

    it("requires http_get for a remote registry", function()
      local registry, err, etype = Registry.new({
        ref = "https://registry.example.com",
        fs_adapter = build_fs()
      })
      assert.is_nil(registry)
      assert.equals("invalid", etype)
      assert.matches("http_get is required", err)
    end)
  end)

  describe("local resolve", function()
    it("resolves the newest satisfying version", function()
      local registry = assert(new_registry(build_fs()))

      local entry = assert(registry:resolve(GUID, "*"))
      assert.equals("1.1.0", entry.version)
      assert.equals("registry-app", entry.name)
      assert.equals("registry-app-1.1.0.cap", entry.file)
      assert.equals(64, #entry.sha256)

      local pinned = assert(registry:resolve(GUID, "=1.0.0"))
      assert.equals("1.0.0", pinned.version)

      local ranged = assert(registry:resolve(GUID, ">=1.0.0 <1.1.0"))
      assert.equals("1.0.0", ranged.version)
    end)

    it("reports not_found for an unknown guid", function()
      local registry = assert(new_registry(build_fs()))
      local entry, err, etype = registry:resolve("capsium://fixtures/nope")
      assert.is_nil(entry)
      assert.equals("not_found", etype)
      assert.matches("no package capsium://fixtures/nope", err)
    end)

    it("reports unsatisfiable with the available versions", function()
      local registry = assert(new_registry(build_fs()))
      local entry, err, etype = registry:resolve(GUID, ">=2.0.0")
      assert.is_nil(entry)
      assert.equals("unsatisfiable", etype)
      assert.matches("satisfies '>=2.0.0'", err)
      assert.matches("1.0.0, 1.1.0", err)
    end)

    it("treats a registry without index.json as empty", function()
      local fs = MockFs.new({})
      local registry = assert(new_registry(fs))
      local entry, err, etype = registry:resolve(GUID)
      assert.is_nil(entry)
      assert.equals("not_found", etype)
      assert.matches("no package", err)
    end)

    it("reports an unparseable index.json as invalid", function()
      local fs = MockFs.new({ ["/registry/index.json"] = "{not json" })
      local registry = assert(new_registry(fs))
      local entry, err, etype = registry:resolve(GUID)
      assert.is_nil(entry)
      assert.equals("invalid", etype)
      assert.matches("not valid JSON", err)
    end)

    it("reports an index without a packages object as invalid", function()
      local fs = MockFs.new({ ["/registry/index.json"] = "{}" })
      local registry = assert(new_registry(fs))
      local entry, err, etype = registry:resolve(GUID)
      assert.is_nil(entry)
      assert.equals("invalid", etype)
      assert.matches('"packages" object', err)
    end)

    it("reports invalid version strings in the index", function()
      local fs = build_fs()
      local index_text = assert(fs.read_file("/registry/index.json"))
      local index = cjson.decode(index_text)
      index.packages[GUID].versions["not-semver"] = {
        file = "x.cap", sha256 = "abc"
      }
      fs.write_file("/registry/index.json", cjson.encode(index))

      local registry = assert(new_registry(fs))
      local entry, err, etype = registry:resolve(GUID)
      assert.is_nil(entry)
      assert.equals("invalid", etype)
      assert.matches("invalid version not%-semver", err)
    end)
  end)

  describe("local install", function()
    it("installs the newest satisfying version into the store", function()
      local fs = build_fs()
      local registry = assert(new_registry(fs))

      local path = assert(registry:install(GUID, ">=1.0.0", "/store"))
      assert.equals("/store/registry-app-1.1.0.cap", path)
      assert.equals("cap-bytes-1.1.0", fs.read_file(path))
    end)

    it("rejects a sha256 mismatch (tampered index)", function()
      local fs = build_fs()
      local index_text = assert(fs.read_file("/registry/index.json"))
      local index = cjson.decode(index_text)
      index.packages[GUID].versions["1.1.0"].sha256 = ("0"):rep(64)
      fs.write_file("/registry/index.json", cjson.encode(index))

      local registry = assert(new_registry(fs))
      local path, err, etype = registry:install(GUID, "*", "/store")
      assert.is_nil(path)
      assert.equals("checksum_mismatch", etype)
      assert.matches("sha256 mismatch for registry%-app%-1.1.0.cap", err)
      assert.is_false(fs.file_exists("/store/registry-app-1.1.0.cap"))
    end)

    it("rejects tampered .cap bytes (index honest, file modified)", function()
      local fs = build_fs({ cap110 = "cap-bytes-1.1.0" })
      -- Overwrite the stored file after the index was computed
      fs.write_file("/registry/registry-app-1.1.0.cap", "TAMPERED BYTES")

      local registry = assert(new_registry(fs))
      local path, err, etype = registry:install(GUID, "*", "/store")
      assert.is_nil(path)
      assert.equals("checksum_mismatch", etype)
      assert.matches("sha256 mismatch", err)
    end)

    it("reports a missing indexed file as invalid", function()
      local fs = build_fs()
      fs.remove("/registry/registry-app-1.1.0.cap")

      local registry = assert(new_registry(fs))
      local path, err, etype = registry:install(GUID, "*", "/store")
      assert.is_nil(path)
      assert.equals("invalid", etype)
      assert.matches("indexed file missing: registry%-app%-1.1.0.cap", err)
    end)

    it("reuses an up-to-date store file (store reuse across restarts)",
    function()
      local fs = build_fs()
      local registry = assert(new_registry(fs))

      local path = assert(registry:install(GUID, "*", "/store"))
      assert.equals("cap-bytes-1.1.0", fs.read_file(path))

      -- Second install (e.g. after a reactor restart): the registry file
      -- is corrupted afterwards, but the matching store file is reused
      -- without a download or checksum failure.
      fs.write_file("/registry/registry-app-1.1.0.cap", "TAMPERED")
      local registry2 = assert(new_registry(fs))
      local path2 = assert(registry2:install(GUID, "*", "/store"))
      assert.equals(path, path2)
      assert.equals("cap-bytes-1.1.0", fs.read_file(path2))
    end)

    it("reinstalls when the store file does not match the index", function()
      local fs = build_fs()
      fs.write_file("/store/registry-app-1.1.0.cap", "stale bytes")

      local registry = assert(new_registry(fs))
      local path = assert(registry:install(GUID, "*", "/store"))
      assert.equals("cap-bytes-1.1.0", fs.read_file(path))
    end)

    it("creates a missing store directory", function()
      local fs = build_fs()
      local registry = assert(new_registry(fs))
      local path = assert(registry:install(GUID, "*", "/var/lib/capsium/store"))
      assert.equals("/var/lib/capsium/store/registry-app-1.1.0.cap", path)
      assert.is_true(fs.dir_exists("/var/lib/capsium/store"))
    end)

    it("requires a store_dir", function()
      local registry = assert(new_registry(build_fs()))
      local path, err, etype = registry:install(GUID, "*", nil)
      assert.is_nil(path)
      assert.equals("not_configured", etype)
      assert.matches("store_dir is required", err)
    end)
  end)

  describe("remote registries", function()
    -- Stub http_get serving a virtual registry over "https".
    local function stub_http(files, log)
      return function(url)
        if log then
          table.insert(log, url)
        end
        local body = files[url]
        if not body then
          return 404, {}, "not found"
        end
        if type(body) == "table" and body.redirect then
          return 302, { location = body.redirect }, ""
        end
        return 200, {}, body
      end
    end

    local function remote_files(opts)
      opts = opts or {}
      local cap = opts.cap or "remote-cap-bytes"
      local base = "https://registry.example.com/capsium"
      local index = {
        packages = {
          [GUID] = {
            name = "registry-app",
            versions = {
              ["1.1.0"] = {
                file = "registry-app-1.1.0.cap",
                sha256 = opts.sha256 or hash.sha256_hex(cap),
                size = #cap
              }
            }
          }
        }
      }
      local files = {
        [base .. "/index.json"] = cjson.encode(index)
      }
      files[base .. "/registry-app-1.1.0.cap"] = cap
      return files, base
    end

    it("resolves and installs over https", function()
      local files, base = remote_files()
      local requests = {}
      local fs = build_fs()
      local registry = assert(Registry.new({
        ref = base,
        fs_adapter = fs,
        http_get = stub_http(files, requests)
      }))

      local path = assert(registry:install(GUID, "*", "/store"))
      assert.equals("/store/registry-app-1.1.0.cap", path)
      assert.equals("remote-cap-bytes", fs.read_file(path))
      assert.equals(base .. "/index.json", requests[1])
      assert.equals(base .. "/registry-app-1.1.0.cap", requests[2])
    end)

    it("follows redirects (scheme revalidated)", function()
      local files, base = remote_files()
      local index_body = files[base .. "/index.json"]
      -- root-relative hop, then a path-relative hop
      files[base .. "/index.json"] = { redirect = "/v2/index.json" }
      files["https://registry.example.com/v2/index.json"] =
        { redirect = "index-final.json" }
      files["https://registry.example.com/v2/index-final.json"] = index_body

      local fs = build_fs()
      local registry = assert(Registry.new({
        ref = base,
        fs_adapter = fs,
        http_get = stub_http(files)
      }))

      local entry = assert(registry:resolve(GUID, "*"))
      assert.equals("1.1.0", entry.version)
    end)

    it("rejects a redirect downgrading to plain http (non-loopback)",
    function()
      local files, base = remote_files()
      files[base .. "/index.json"] =
        { redirect = "http://evil.example.com/index.json" }

      local fs = build_fs()
      local registry = assert(Registry.new({
        ref = base,
        fs_adapter = fs,
        http_get = stub_http(files)
      }))

      local entry, err, etype = registry:resolve(GUID, "*")
      assert.is_nil(entry)
      assert.equals("invalid", etype)
      assert.matches("must use https", err)
    end)

    it("reports an unreadable remote index as invalid", function()
      local fs = build_fs()
      local registry = assert(Registry.new({
        ref = "https://registry.example.com/capsium",
        fs_adapter = fs,
        http_get = stub_http({})
      }))

      local entry, err, etype = registry:resolve(GUID, "*")
      assert.is_nil(entry)
      assert.equals("invalid", etype)
      assert.matches("no readable index.json", err)
      assert.matches("HTTP 404", err)
    end)

    it("reports transport failures as fetch errors", function()
      local files, base = remote_files()
      local fs = build_fs()
      local registry = assert(Registry.new({
        ref = base,
        fs_adapter = fs,
        http_get = function(url)
          if url:match("index%.json$") then
            return 200, {}, files[url]
          end
          return nil, "connection refused"
        end
      }))

      local path, err, etype = registry:install(GUID, "*", "/store")
      assert.is_nil(path)
      assert.equals("fetch", etype)
      assert.matches("connection refused", err)
    end)

    it("verifies sha256 on remote installs", function()
      local files, base = remote_files({ sha256 = ("f"):rep(64) })
      local fs = build_fs()
      local registry = assert(Registry.new({
        ref = base,
        fs_adapter = fs,
        http_get = stub_http(files)
      }))

      local path, err, etype = registry:install(GUID, "*", "/store")
      assert.is_nil(path)
      assert.equals("checksum_mismatch", etype)
      assert.matches("sha256 mismatch", err)
    end)

    it("gives up after too many redirects", function()
      local base = "https://registry.example.com/capsium"
      local fs = build_fs()
      local registry = assert(Registry.new({
        ref = base,
        fs_adapter = fs,
        http_get = function(url)
          return 302, { location = url .. "/loop" }, ""
        end
      }))

      local entry, err, etype = registry:resolve(GUID, "*")
      assert.is_nil(entry)
      assert.equals("invalid", etype)
      assert.matches("too many redirects", err)
    end)
  end)
end)
