describe("layered storage (ARCHITECTURE.md section 5a)", function()
  local router = require "capsium.package.router"
  local Package = require "capsium.package.package"
  local MockFs = require "mock_fs"
  local cjson = require "cjson"

  describe("router.normalize_layers", function()
    it("parses the canonical storage.json form", function()
      local layers = assert(router.normalize_layers({
        storage = {
          layers = {
            { path = "base", writable = false, visibility = "exported" },
            { path = "updates", writable = true, visibility = "private" }
          }
        }
      }))

      assert.equals(2, #layers)
      assert.equals("base", layers[1].path)
      assert.is_false(layers[1].writable)
      assert.equals("exported", layers[1].visibility)
      assert.equals("updates", layers[2].path)
      assert.is_true(layers[2].writable)
      assert.equals("private", layers[2].visibility)
    end)

    it("accepts the manifest.json top-level form (05x-storage)", function()
      local layers = assert(router.normalize_layers({
        layers = {
          { path = "base", writable = false, visibility = "exported" }
        }
      }))

      assert.equals(1, #layers)
      assert.equals("base", layers[1].path)
    end)

    it("prefers storage.layers over a top-level layers key", function()
      local layers = assert(router.normalize_layers({
        storage = { layers = { { path = "from-storage" } } },
        layers = { { path = "from-manifest" } }
      }))

      assert.equals("from-storage", layers[1].path)
    end)

    it("defaults visibility to exported and writable to false", function()
      local layers = assert(router.normalize_layers({
        storage = { layers = { { path = "base" } } }
      }))

      assert.equals("exported", layers[1].visibility)
      assert.is_false(layers[1].writable)
    end)

    it("skips unsafe layer paths", function()
      local layers = router.normalize_layers({
        storage = {
          layers = {
            { path = "/absolute" },
            { path = "../escape" },
            { path = "nested/../escape" },
            { path = "" },
            { writable = true },
            "not-a-table",
            { path = "ok" }
          }
        }
      })

      assert.equals(1, #layers)
      assert.equals("ok", layers[1].path)
    end)

    it("returns nil when no usable layers are configured", function()
      assert.is_nil(router.normalize_layers({}))
      assert.is_nil(router.normalize_layers({ storage = {} }))
      assert.is_nil(router.normalize_layers({
        storage = { layers = { { path = "/absolute" } } }
      }))
      assert.is_nil(router.normalize_layers(nil))
    end)
  end)

  describe("Package layered resolution", function()
    local function build_package(extra_files, storage_layers)
      local files = {
        ["/pkg/metadata.json"] =
          '{"name":"layered-pkg","version":"1.0.0"}',
        ["/pkg/routes.json"] = cjson.encode({
          index = "content/index.html",
          routes = {
            { path = "/", resource = "content/index.html" },
            { path = "/index.html", resource = "content/index.html" },
            { path = "/base-only", resource = "content/base-only.html" },
            { path = "/deprecated", resource = "content/deprecated.html" }
          }
        }),
        ["/pkg/base/content/index.html"] = "<h1>base index</h1>",
        ["/pkg/base/content/base-only.html"] = "<h1>base only</h1>",
        ["/pkg/base/content/deprecated.html"] = "<h1>deprecated</h1>",
        ["/pkg/updates/content/index.html"] = "<h1>updated index</h1>"
      }
      for path, content in pairs(extra_files or {}) do
        files[path] = content
      end

      if storage_layers ~= false then
        files["/pkg/storage.json"] = cjson.encode({
          storage = {
            layers = storage_layers or {
              { path = "base", writable = false, visibility = "exported" },
              { path = "updates", writable = true, visibility = "private" }
            }
          }
        })
      end

      local fs = MockFs.new(files)
      local package = Package.new("/pkg", { fs_adapter = fs })
      assert(package:load())
      return package
    end

    it("resolves top-to-bottom: the top layer wins", function()
      local package = build_package()
      local target = assert(package:resolve("/"))

      assert.equals("static", target.kind)
      assert.is_truthy(target.path:find("updates/content/index%.html$"))
    end)

    it("falls through to lower layers for files only they have", function()
      local package = build_package()
      local target = assert(package:resolve("/base-only"))

      assert.is_truthy(target.path:find("base/content/base%-only%.html$"))
    end)

    it("resolves 404 for files in no layer", function()
      local package = build_package()
      local target, err = package:resolve("/nope")

      assert.is_nil(target)
      assert.is_truthy(tostring(err):find("Route not found"))
    end)

    it("treats tombstoned paths as deleted even when a lower layer has them",
       function()
      local package = build_package({
        ["/pkg/updates/.capsium-tombstones"] =
          '["content/deprecated.html"]'
      })

      local target, err = package:resolve("/deprecated")
      assert.is_nil(target)
      assert.is_truthy(tostring(err):find("tombstoned"))
    end)

    it("serves non-tombstoned lower files when a tombstone list exists",
       function()
      local package = build_package({
        ["/pkg/updates/.capsium-tombstones"] =
          '["content/deprecated.html"]'
      })

      local target = assert(package:resolve("/base-only"))
      assert.is_truthy(target.path:find("base/content/"))
    end)

    it("lets a file sharing a layer with its tombstone win", function()
      -- Tombstone list lives in the SAME (read-only base) layer as the
      -- file: descending, the file is found in that layer before the
      -- tombstone can mask lower layers
      local package = build_package({
        ["/pkg/base/.capsium-tombstones"] = '["content/deprecated.html"]'
      })

      local target = assert(package:resolve("/deprecated"))
      assert.is_truthy(target.path:find("base/content/deprecated%.html$"))
    end)

    it("honors tombstones in any layer, masking lower layers", function()
      -- 3 layers; the tombstone in the MIDDLE layer masks the bottom one
      local files = {
        ["/pkg/middle/.capsium-tombstones"] =
          '["content/deprecated.html"]',
        ["/pkg/middle/content/index.html"] = "<h1>middle</h1>"
      }
      local package = build_package(files, {
        { path = "base", writable = false, visibility = "exported" },
        { path = "middle", writable = false, visibility = "exported" },
        { path = "updates", writable = true, visibility = "private" }
      })

      local target, err = package:resolve("/deprecated")
      assert.is_nil(target)
      assert.is_truthy(tostring(err):find("tombstoned"))

      -- and unrelated lower files still serve
      local ok = assert(package:resolve("/base-only"))
      assert.is_truthy(ok.path:find("base/content/"))
    end)

    it("ignores a malformed tombstone file", function()
      local package = build_package({
        ["/pkg/updates/.capsium-tombstones"] = "not json"
      })

      local target = assert(package:resolve("/deprecated"))
      assert.is_truthy(target.path:find("base/content/deprecated%.html$"))
    end)

    it("exposes the parsed layers with visibility", function()
      local package = build_package()
      local layers = package:get_layers()

      assert.equals(2, #layers)
      assert.equals("exported", layers[1].visibility)
      assert.equals("private", layers[2].visibility)
    end)

    it("resolves from the package root when no layers are configured",
       function()
      local files = {
        ["/pkg/metadata.json"] =
          '{"name":"plain-pkg","version":"1.0.0"}',
        ["/pkg/content/index.html"] = "<h1>root</h1>"
      }
      local fs = MockFs.new(files)
      local package = Package.new("/pkg", { fs_adapter = fs })
      assert(package:load())

      local target = assert(package:resolve("/"))
      assert.equals("/pkg/content/index.html", target.path)
      assert.is_nil(package:get_layers())
    end)
  end)
end)
