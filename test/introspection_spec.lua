describe("reactor + per-package introspection reports (07-reactor)",
function()
  local Reactor = require "capsium.reactor"
  local utils = require "capsium.utils"

  local function mock_package(metadata, valid)
    return {
      get_metadata = function()
        return metadata
      end,
      verify_integrity = function()
        return valid, valid and nil or "checksum mismatch"
      end
    }
  end

  describe("status_report", function()
    it("reports running with uptime and package count", function()
      local report = Reactor.status_report(os.time() - 42, 15)
      assert.equals("running", report.status)
      assert.is_true(report.uptime >= 42)
      assert.equals(15, report.packagesLoaded)
    end)

    it("never reports a negative uptime", function()
      local report = Reactor.status_report(os.time() + 60, 0)
      assert.equals(0, report.uptime)
    end)
  end)

  describe("metrics_report", function()
    it("merges the shared-dict snapshot with uptime", function()
      local report = Reactor.metrics_report(os.time() - 5, {
        requestsTotal = 7,
        requestsByStatus = { ["200"] = 5, ["404"] = 2 }
      })
      assert.is_true(report.uptime >= 5)
      assert.equals(7, report.requestsTotal)
      assert.equals(5, report.requestsByStatus["200"])
      assert.equals(2, report.requestsByStatus["404"])
    end)

    it("tolerates an empty snapshot", function()
      local report = Reactor.metrics_report(os.time(), nil)
      assert.equals(0, report.requestsTotal)
      assert.same({}, report.requestsByStatus)
    end)
  end)

  describe("package_status_report", function()
    it("reports a loaded valid package", function()
      local report = Reactor.package_status_report(mock_package({
        name = "registry-app", version = "1.1.0"
      }, true))
      assert.equals("registry-app", report.package)
      assert.equals("1.1.0", report.version)
      assert.equals("loaded", report.status)
      assert.is_true(report.valid)
    end)

    it("reports integrity failures", function()
      local report = Reactor.package_status_report(mock_package({
        name = "broken", version = "1.0.0"
      }, false))
      assert.is_false(report.valid)
    end)
  end)

  describe("package_metadata_report", function()
    it("reports the canonical metadata fields", function()
      local report = Reactor.package_metadata_report(mock_package({
        name = "story-of-claire",
        version = "1.0.0",
        description = "An example Capsium package",
        author = "Ribose",
        guid = "https://github.com/capsiums/cap-story"
      }, true))
      assert.equals("story-of-claire", report.name)
      assert.equals("1.0.0", report.version)
      assert.equals("An example Capsium package", report.description)
      assert.equals("Ribose", report.author)
      assert.equals("https://github.com/capsiums/cap-story", report.guid)
    end)
  end)

  describe("package_logs_report", function()
    it("wraps the ring-buffer lines with the package name", function()
      local report = Reactor.package_logs_report(mock_package({
        name = "registry-app"
      }, true), { "line one", "line two" })
      assert.equals("registry-app", report.package)
      assert.same({ "line one", "line two" }, report.logs)
    end)

    it("defaults to no lines", function()
      local report = Reactor.package_logs_report(mock_package({
        name = "registry-app"
      }, true), nil)
      assert.same({}, report.logs)
    end)
  end)

  describe("utils.redact_url", function()
    it("strips userinfo from http(s) URLs", function()
      assert.equals("https://registry.example.com/capsium",
        utils.redact_url("https://user:secret@registry.example.com/capsium"))
      assert.equals("http://127.0.0.1:8080/reg",
        utils.redact_url("http://deploy:token@127.0.0.1:8080/reg"))
    end)

    it("leaves URLs without userinfo and plain paths unchanged", function()
      assert.equals("https://registry.example.com/capsium",
        utils.redact_url("https://registry.example.com/capsium"))
      assert.equals("/var/lib/capsium/registry",
        utils.redact_url("/var/lib/capsium/registry"))
    end)

    it("passes non-strings through", function()
      assert.is_nil(utils.redact_url(nil))
    end)
  end)
end)
