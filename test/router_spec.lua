describe("Capsium route normalization and generation", function()
  local router = require "capsium.package.router"

  describe("normalize_manifest", function()
    it("accepts the canonical resources form", function()
      local resources = router.normalize_manifest({
        resources = {
          ["content/index.html"] = { type = "text/html" },
          ["content/app.js"] = { type = "text/javascript",
                                 visibility = "private" }
        }
      })

      assert.equals("text/html", resources["content/index.html"].type)
      assert.equals("exported", resources["content/index.html"].visibility)
      assert.equals("private", resources["content/app.js"].visibility)
    end)

    it("normalizes the legacy content array form", function()
      local resources = router.normalize_manifest({
        content = {
          { file = "index.html", mime = "text/html" },
          { file = "docs/guide.html", mime = "text/html" }
        }
      })

      assert.equals("text/html", resources["content/index.html"].type)
      assert.equals("text/html", resources["content/docs/guide.html"].type)
    end)

    it("normalizes the legacy content object form", function()
      local resources = router.normalize_manifest({
        content = {
          ["index.html"] = "text/html",
          ["styles.css"] = "text/css"
        }
      })

      assert.equals("text/html", resources["content/index.html"].type)
      assert.equals("text/css", resources["content/styles.css"].type)
    end)

    it("returns nil for non-manifest input", function()
      assert.is_nil(router.normalize_manifest({ name = "x" }))
      assert.is_nil(router.normalize_manifest(nil))
      assert.is_nil(router.normalize_manifest("nope"))
    end)
  end)

  describe("normalize_storage", function()
    it("accepts the canonical dataSets form", function()
      local datasets = router.normalize_storage({
        storage = {
          dataSets = {
            animals = { source = "data/animals.json",
                        schemaType = "json-schema" }
          }
        }
      })

      assert.equals("data/animals.json", datasets.animals.source)
      assert.equals("json-schema", datasets.animals.schemaType)
    end)

    it("normalizes the legacy datasets array form", function()
      local datasets = router.normalize_storage({
        datasets = {
          { name = "animals", source = "data/animals.json",
            format = "json", schema = "data/animals.schema.json" }
        }
      })

      assert.equals("data/animals.json", datasets.animals.source)
      assert.equals("json", datasets.animals.format)
    end)

    it("treats absent storage as an empty map", function()
      assert.are_same({}, router.normalize_storage(nil))
      assert.are_same({}, router.normalize_storage({ datasets = {} }))
    end)
  end)

  describe("normalize_routes", function()
    it("accepts the canonical array form", function()
      local routes, index = router.normalize_routes({
        index = "content/index.html",
        routes = {
          { path = "/", resource = "content/index.html" },
          { path = "/styles.css", resource = "content/styles.css",
            headers = { ["Cache-Control"] = "public, max-age=31536000" } },
          { path = "/api/v1/data/animals", dataset = "animals" },
          { path = "/hook", method = "POST", handler = "hook.lua" }
        }
      })

      assert.equals("content/index.html", index)
      assert.equals(4, #routes)
      assert.equals("content/index.html", routes[1].resource)
      assert.equals("public, max-age=31536000",
                    routes[2].headers["Cache-Control"])
      assert.equals("animals", routes[3].dataset)
      assert.equals("hook.lua", routes[4].handler)
    end)

    it("normalizes the legacy array form with content-relative targets",
       function()
      local routes = router.normalize_routes({
        routes = {
          { path = "/", target = { file = "index.html" } },
          { path = "/documents.xml", target = { file = "documents.xml" } }
        }
      })

      assert.equals(2, #routes)
      assert.equals("content/index.html", routes[1].resource)
      assert.equals("content/documents.xml", routes[2].resource)
    end)

    it("normalizes the legacy object form", function()
      local routes = router.normalize_routes({
        routes = {
          ["/"] = { target = { file = "index.html" } }
        }
      })

      assert.equals(1, #routes)
      assert.equals("/", routes[1].path)
      assert.equals("content/index.html", routes[1].resource)
    end)

    it("keeps content/ prefixes in legacy targets", function()
      local routes = router.normalize_routes({
        routes = {
          { path = "/", target = { file = "content/index.html" } }
        }
      })

      assert.equals("content/index.html", routes[1].resource)
    end)

    it("normalizes legacy target.dataset routes (array and object forms)",
       function()
      local from_array = router.normalize_routes({
        routes = {
          { path = "/api/v1/data/animals", target = { dataset = "animals" } }
        }
      })
      assert.equals("animals", from_array[1].dataset)

      local from_object = router.normalize_routes({
        routes = {
          ["/api/v1/data/animals"] = { target = { dataset = "animals" } }
        }
      })
      assert.equals("animals", from_object[1].dataset)
    end)

    it("returns nil, err for invalid input", function()
      local routes, err = router.normalize_routes({})
      assert.is_nil(routes)
      assert.is_string(err)
    end)
  end)

  describe("generate_routes (auto-generation goldens, ARCHITECTURE.md §4)",
  function()
    local resources = {
      ["content/index.html"] = { type = "text/html" },
      ["content/about.html"] = { type = "text/html" },
      ["content/docs/guide.html"] = { type = "text/html" },
      ["content/assets/app.js"] = { type = "text/javascript" },
      ["data/animals.json"] = { type = "application/json" }
    }
    local datasets = {
      animals = { source = "data/animals.json" },
      plants = { source = "data/plants.csv" }
    }

    local routes = router.generate_routes(resources, datasets)

    local by_path = {}
    for _, route in ipairs(routes) do
      by_path[route.path] = route
    end

    it("routes / to the index", function()
      assert.equals("content/index.html", by_path["/"].resource)
      assert.equals("/", routes[1].path) -- root first
    end)

    it("gives HTML files dual routes (basename + full filename)", function()
      assert.equals("content/index.html", by_path["/index"].resource)
      assert.equals("content/index.html", by_path["/index.html"].resource)
      assert.equals("content/about.html", by_path["/about"].resource)
      assert.equals("content/about.html", by_path["/about.html"].resource)
      assert.equals("content/docs/guide.html",
                    by_path["/docs/guide"].resource)
      assert.equals("content/docs/guide.html",
                    by_path["/docs/guide.html"].resource)
    end)

    it("routes every content resource relative to content/", function()
      assert.equals("content/assets/app.js",
                    by_path["/assets/app.js"].resource)
    end)

    it("does not route non-content resources as static files", function()
      assert.is_nil(by_path["/data/animals.json"])
    end)

    it("routes datasets under /api/v1/data/<id>", function()
      assert.equals("animals", by_path["/api/v1/data/animals"].dataset)
      assert.equals("plants", by_path["/api/v1/data/plants"].dataset)
    end)

    it("honors a custom index resource", function()
      local custom = router.generate_routes({
        ["content/home.html"] = { type = "text/html" }
      }, {}, "content/home.html")

      assert.equals("content/home.html", custom[1].resource)
      assert.equals("/", custom[1].path)
    end)

    it("omits / when there is no index resource", function()
      local no_index = router.generate_routes({
        ["content/about.html"] = { type = "text/html" }
      })

      local paths = {}
      for _, route in ipairs(no_index) do
        paths[route.path] = true
      end
      assert.is_nil(paths["/"])
      assert.is_true(paths["/about"])
    end)

    it("produces deterministic output", function()
      local again = router.generate_routes(resources, datasets)
      assert.are_same(routes, again)
    end)
  end)

  describe("resolve", function()
    local routes = {
      { path = "/", resource = "content/index.html" },
      { path = "/about", resource = "content/about.html" },
      { path = "/docs/", resource = "content/docs/index.html" }
    }

    it("resolves exact paths", function()
      assert.equals("content/about.html",
                    router.resolve(routes, "/about").resource)
    end)

    it("tolerates trailing slash differences", function()
      assert.equals("content/about.html",
                    router.resolve(routes, "/about/").resource)
      assert.equals("content/docs/index.html",
                    router.resolve(routes, "/docs").resource)
    end)

    it("returns nil for unknown paths", function()
      assert.is_nil(router.resolve(routes, "/nope"))
    end)
  end)

  describe("resource_mime (issue #10 — manifest wins, extension fallback)", function()
    it("returns the manifest-declared type when present", function()
      local resources = {
        ["content/index.html"] = { type = "application/xhtml+xml" }
      }
      assert.equals("application/xhtml+xml",
                    router.resource_mime(resources, "content/index.html"))
    end)

    it("falls back to extension-derived type when manifest lacks one", function()
      local resources = {
        ["content/index.html"] = {}
      }
      assert.equals("text/html",
                    router.resource_mime(resources, "content/index.html"))
    end)

    it("falls back to extension when resources map is nil", function()
      assert.equals("text/html",
                    router.resource_mime(nil, "content/index.html"))
    end)

    it("manifest type wins over a conflicting extension-derived type", function()
      local resources = {
        ["content/data.json"] = { type = "application/vnd.custom+json" }
      }
      assert.equals("application/vnd.custom+json",
                    router.resource_mime(resources, "content/data.json"))
    end)
  end)
end)
