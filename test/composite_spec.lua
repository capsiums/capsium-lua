describe("composite packages (ARCHITECTURE.md section 4a)", function()
  local composite = require "capsium.package.composite"
  local Store = require "capsium.package.store"
  local Package = require "capsium.package.package"
  local Reactor = require "capsium.reactor"
  local MockFs = require "mock_fs"
  local MockZip = require "mock_zip"
  local hash = require "capsium.adapters.hash"
  local cjson = require "cjson"

  describe("composite.is_dependency_ref / parse_ref", function()
    it("detects dependency references (any guid URI)", function()
      assert.is_true(composite.is_dependency_ref(
        "capsium://example.com/core/content/app.js"))
      assert.is_true(composite.is_dependency_ref(
        "https://example.com/core/content/app.js"))
      assert.is_false(composite.is_dependency_ref("content/app.js"))
      assert.is_false(composite.is_dependency_ref(nil))
    end)

    it("parses against dependency guids (literal guid prefix)", function()
      local ref = assert(composite.parse_ref(
        "capsium://example.com/core/content/app.js",
        { "capsium://example.com/core" }))

      assert.equals("capsium://example.com/core", ref.guid)
      assert.equals("content/app.js", ref.path)

      -- https:// guids (the reference form used by the conformance kit)
      local https_ref = assert(composite.parse_ref(
        "https://conformance.capsiums.dev/core/content/public.txt",
        { "https://conformance.capsiums.dev/core" }))

      assert.equals("https://conformance.capsiums.dev/core",
                    https_ref.guid)
      assert.equals("content/public.txt", https_ref.path)
    end)

    it("prefers the longest matching guid prefix", function()
      local ref = assert(composite.parse_ref(
        "capsium://example.com/core/extra/content/app.js",
        { "capsium://example.com/core", "capsium://example.com/core/extra" }))

      assert.equals("capsium://example.com/core/extra", ref.guid)
      assert.equals("content/app.js", ref.path)
    end)

    it("returns nil when no guid matches", function()
      assert.is_nil(composite.parse_ref(
        "capsium://unknown.org/pkg/content/app.js",
        { "capsium://example.com/core" }))
    end)
  end)

  describe("composite.apply_response_processing", function()
    it("adds responseHeaders only when absent", function()
      local target = composite.apply_response_processing({
        headers = { ["X-Existing"] = "original" }
      }, {
        responseHeaders = {
          ["X-Existing"] = "changed",
          ["X-New"] = "added"
        }
      })

      assert.equals("original", target.headers["X-Existing"])
      assert.equals("added", target.headers["X-New"])
    end)

    it("overrides headers with responseRewrite.headers", function()
      local target = composite.apply_response_processing({
        headers = { ["X-Existing"] = "original" }
      }, {
        responseRewrite = { headers = { ["X-Existing"] = "rewritten" } }
      })

      assert.equals("rewritten", target.headers["X-Existing"])
    end)

    it("replaces the body with responseRewrite.body", function()
      local target = composite.apply_response_processing({
        path = "/pkg/content/file.txt",
        headers = {}
      }, {
        responseRewrite = { body = "replacement" }
      })

      assert.equals("replacement", target.body)
      assert.is_nil(target.path)
    end)
  end)

  describe("package store", function()
    local function build_store()
      local fs = MockFs.new({
        ["/store/vendor-core-1.0.0.cap"] = "blob1",
        ["/store/vendor-core-1.1.0.cap"] = "blob2",
        ["/store/other-2.0.0.cap"] = "blob3"
      })
      local zip = MockZip.new({
        ["/store/vendor-core-1.0.0.cap"] = {
          files = {
            { name = "metadata.json",
              content = cjson.encode({
                name = "vendor-core", version = "1.0.0",
                guid = "capsium://fixtures/vendor-core"
              }) }
          }
        },
        ["/store/vendor-core-1.1.0.cap"] = {
          files = {
            { name = "metadata.json",
              content = cjson.encode({
                name = "vendor-core", version = "1.1.0",
                guid = "capsium://fixtures/vendor-core"
              }) }
          }
        },
        ["/store/other-2.0.0.cap"] = {
          files = {
            { name = "metadata.json",
              content = cjson.encode({
                name = "other", version = "2.0.0",
                guid = "capsium://fixtures/other"
              }) }
          }
        }
      })
      return Store.new({
        store_dir = "/store", fs_adapter = fs, zip_adapter = zip
      })
    end

    it("scans candidates from the store directory", function()
      local store = build_store()
      local candidates = store:candidates()

      assert.equals(3, #candidates)
      assert.equals("capsium://fixtures/other", candidates[1].guid)
      assert.equals("capsium://fixtures/vendor-core", candidates[2].guid)
      assert.equals("1.0.0", candidates[2].version)
      assert.equals("1.1.0", candidates[3].version)
    end)

    it("plans dependencies to the newest satisfying version", function()
      local store = build_store()
      local plan = assert(store:plan({
        ["capsium://fixtures/vendor-core"] = ">=1.0.0"
      }))

      assert.equals("1.1.0",
                    plan["capsium://fixtures/vendor-core"].version)
      assert.equals("/store/vendor-core-1.1.0.cap",
                    plan["capsium://fixtures/vendor-core"].file)
    end)

    it("lists every unsatisfiable dependency", function()
      local store = build_store()
      local plan, err = store:plan({
        ["capsium://fixtures/vendor-core"] = ">=9.0.0",
        ["capsium://fixtures/missing"] = "*"
      })

      assert.is_nil(plan)
      assert.is_truthy(err:find("vendor%-core"))
      assert.is_truthy(err:find("missing"))
    end)

    it("treats a missing store directory as empty candidates", function()
      local store = Store.new({
        store_dir = "/no/such/dir",
        fs_adapter = MockFs.new({}),
        zip_adapter = MockZip.new({})
      })

      assert.same({}, store:candidates())
      local plan, err = store:plan({ ["capsium://fixtures/x"] = "*" })
      assert.is_nil(plan)
      assert.is_truthy(err:find("unsatisfiable"))
    end)
  end)

  describe("reactor with a package store", function()
    local VENDOR_GUID = "capsium://fixtures/vendor-core"

    -- Composite package routes exercising section-4a route inheritance
    local function composite_routes()
      return cjson.encode({
        index = "content/index.html",
        routes = {
          { path = "/", resource = "content/index.html" },
          { path = "/vendor/app.js",
            resource = VENDOR_GUID .. "/content/app.js" },
          { path = "/vendor/old-app.js",
            resource = VENDOR_GUID .. "/content/app.js",
            remap = "/vendor/legacy-app.js" },
          { path = "/vendor/greeting",
            resource = VENDOR_GUID .. "/content/greeting.txt",
            responseHeaders = { ["X-From"] = "composite" } },
          { path = "/vendor/rewritten",
            resource = VENDOR_GUID .. "/content/greeting.txt",
            responseRewrite = {
              body = "rewritten by composite",
              headers = { ["X-Rewritten"] = "yes" }
            } },
          { path = "/vendor/secret",
            resource = VENDOR_GUID .. "/content/secret.txt" },
          { path = "/fallthrough/greeting.txt",
            resource = "content/greeting.txt" },
          { path = "/fallthrough/secret.txt",
            resource = "content/secret.txt" }
        }
      })
    end

    local function vendor_files(version)
      return {
        { name = "metadata.json",
          content = cjson.encode({
            name = "vendor-core", version = version, guid = VENDOR_GUID
          }) },
        { name = "manifest.json",
          content = cjson.encode({
            resources = {
              ["content/index.html"] = {
                type = "text/html", visibility = "exported"
              },
              ["content/app.js"] = {
                type = "text/javascript", visibility = "exported"
              },
              ["content/greeting.txt"] = {
                type = "text/plain", visibility = "exported"
              },
              ["content/secret.txt"] = {
                type = "text/plain", visibility = "private"
              }
            }
          }) },
        { name = "content/index.html",
          content = "<h1>vendor " .. version .. "</h1>" },
        { name = "content/app.js",
          content = "vendor core " .. version },
        { name = "content/greeting.txt", content = "hello from vendor" },
        { name = "content/secret.txt", content = "vendor internal" }
      }
    end

    local function build_reactor(deps)
      local fs = MockFs.new({
        ["/packages/composite-1.0.0.cap"] = "composite blob",
        ["/store/vendor-core-1.0.0.cap"] = "vendor 1.0.0 blob",
        ["/store/vendor-core-1.1.0.cap"] = "vendor 1.1.0 blob"
      })
      local zip = MockZip.new({
        ["/packages/composite-1.0.0.cap"] = {
          files = {
            { name = "metadata.json",
              content = cjson.encode({
                name = "composite", version = "1.0.0",
                guid = "capsium://fixtures/composite",
                dependencies = deps or {
                  [VENDOR_GUID] = ">=1.0.0"
                }
              }) },
            { name = "routes.json", content = composite_routes() },
            { name = "content/index.html", content = "<h1>composite</h1>" }
          }
        },
        ["/store/vendor-core-1.0.0.cap"] = { files = vendor_files("1.0.0") },
        ["/store/vendor-core-1.1.0.cap"] = { files = vendor_files("1.1.0") }
      })

      return Reactor.new({
        package_dir = "/packages",
        extract_dir = "/extracted",
        store_dir = "/store",
        fs_adapter = fs,
        zip_adapter = zip,
        hash_fn = function(path)
          local content = fs:read_file(path)
          return content and hash.sha256_hex(content) or nil
        end
      }), fs
    end

    it("mounts the newest satisfying dependency version", function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      local target = assert(package:resolve("/vendor/app.js"))
      local fs = reactor.fs_adapter
      assert.equals("vendor core 1.1.0", fs.read_file(target.path))
    end)

    it("serves the composite package's own content", function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      local target = assert(package:resolve("/"))
      assert.is_truthy(target.path:find(
        "composite%-1%.0%.0/content/index%.html$"))
    end)

    it("serves remapped routes at the remap path only", function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      local target = assert(package:resolve("/vendor/legacy-app.js"))
      assert.is_truthy(target.path:find("app%.js$"))

      local missing = package:resolve("/vendor/old-app.js")
      assert.is_nil(missing)
    end)

    it("adds responseHeaders to inherited routes", function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      local target = assert(package:resolve("/vendor/greeting"))
      assert.equals("composite", target.headers["X-From"])
    end)

    it("rewrites body and headers with responseRewrite", function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      local target = assert(package:resolve("/vendor/rewritten"))
      assert.equals("rewritten by composite", target.body)
      assert.is_nil(target.path)
      assert.equals("yes", target.headers["X-Rewritten"])
    end)

    it("rejects references to a dependency's private resource", function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      local target, err = package:resolve("/vendor/secret")
      assert.is_nil(target)
      assert.is_truthy(tostring(err):find("private"))
    end)

    it("falls through to dependency content after own layers miss", function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      local target = assert(package:resolve("/fallthrough/greeting.txt"))
      local fs = reactor.fs_adapter
      assert.equals("hello from vendor", fs.read_file(target.path))
    end)

    it("does not expose a dependency's private resource via fallthrough",
       function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      local target = package:resolve("/fallthrough/secret.txt")
      assert.is_nil(target)
    end)

    it("own content shadows dependency content on fallthrough", function()
      local reactor = build_reactor()
      local package = assert(reactor:get_package("composite-1.0.0"))

      -- content/index.html exists in both; the own file wins
      local target = assert(package:resolve("/"))
      assert.is_truthy(target.path:find(
        "composite%-1%.0%.0/content/index%.html$"))
    end)

    it("rejects references with no installed dependency", function()
      local reactor = build_reactor({ [VENDOR_GUID] = ">=1.0.0" })
      local package = assert(reactor:get_package("composite-1.0.0"))

      -- Rewrite the /vendor/secret reference to an unknown guid
      for _, route in ipairs(package:get_routes()) do
        if route.path == "/vendor/secret" then
          route.resource = "capsium://unknown.org/x/content/secret.txt"
        end
      end

      local target, err = package:resolve("/vendor/secret")
      assert.is_nil(target)
      assert.is_truthy(tostring(err):find("not installed"))
    end)

    it("fails with unsatisfiable dependencies", function()
      local reactor = build_reactor({ [VENDOR_GUID] = ">=9.0.0" })
      local package, err = reactor:get_package("composite-1.0.0")

      assert.is_nil(package)
      assert.is_truthy(tostring(err):find("unsatisfiable"))
    end)

    it("fails when no store is configured", function()
      local reactor = build_reactor()
      reactor.store_dir = nil

      local package, err = reactor:get_package("composite-1.0.0")
      assert.is_nil(package)
      assert.is_truthy(tostring(err):find("no package store"))
    end)

    it("detects dependency cycles", function()
      -- vendor depends back on the composite package
      local reactor, fs = build_reactor()
      local zip = reactor.zip_adapter
      zip.archives["/store/vendor-core-1.0.0.cap"].files[1].content =
        cjson.encode({
          name = "vendor-core", version = "1.0.0", guid = VENDOR_GUID,
          dependencies = { ["capsium://fixtures/composite"] = ">=1.0.0" }
        })
      zip.archives["/store/vendor-core-1.1.0.cap"].files[1].content =
        cjson.encode({
          name = "vendor-core", version = "1.1.0", guid = VENDOR_GUID,
          dependencies = { ["capsium://fixtures/composite"] = ">=1.0.0" }
        })
      -- The store must offer the composite package for the cycle to close
      fs:write_file("/store/composite-1.0.0.cap", "composite blob")
      zip.archives["/store/composite-1.0.0.cap"] =
        zip.archives["/packages/composite-1.0.0.cap"]

      local package, err = reactor:get_package("composite-1.0.0")
      assert.is_nil(package)
      assert.is_truthy(tostring(err):find("cycle"))
    end)
  end)

  describe("dependency with private layers", function()
    it("hides private-layer content from dependents", function()
      local dep = Package.new("/dep", {
        fs_adapter = MockFs.new({
          ["/dep/metadata.json"] =
            '{"name":"dep","version":"1.0.0"}',
          ["/dep/manifest.json"] = cjson.encode({
            resources = {
              ["content/visible.txt"] = { type = "text/plain" },
              ["content/hidden.txt"] = { type = "text/plain" }
            }
          }),
          ["/dep/storage.json"] = cjson.encode({
            storage = {
              layers = {
                { path = "base", visibility = "exported" },
                { path = "updates", visibility = "private" }
              }
            }
          }),
          ["/dep/base/visible.txt"] = "visible",
          ["/dep/updates/hidden.txt"] = "hidden"
        })
      })
      assert(dep:load())

      local dependent = Package.new("/dependent", {
        fs_adapter = MockFs.new({
          ["/dependent/metadata.json"] =
            '{"name":"dependent","version":"1.0.0"}'
        })
      })
      assert(dependent:load())
      dependent:set_dependencies({ ["capsium://fixtures/dep"] = dep })

      local visible = assert(dependent:resolve_dependency_ref({
        resource = "capsium://fixtures/dep/content/visible.txt",
        headers = nil
      }))
      assert.equals("/dep/base/visible.txt", visible.path)

      local hidden, err = dependent:resolve_dependency_ref({
        resource = "capsium://fixtures/dep/content/hidden.txt"
      })
      assert.is_nil(hidden)
      assert.is_truthy(tostring(err):find("missing"))
    end)
  end)
end)
