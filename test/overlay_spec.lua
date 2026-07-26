local Overlay = require "capsium.package.overlay"

local function with_tmpdir(fn)
  local tmp = os.tmpname()
  os.remove(tmp)
  -- mkdir via lfs (test dependency)
  local lfs = require "lfs"
  assert(lfs.mkdir(tmp))
  local ok, err = pcall(fn, tmp)
  lfs.rmdir(tmp) -- may fail if not empty; ignore
  return ok, err
end

describe("capsium.package.overlay", function()
  describe("new", function()
    it("creates the workdir tree on construction", function()
      with_tmpdir(function(tmp)
        local overlay, err = Overlay.new(tmp, "demo")
        assert.is_nil(err)
        assert.is_table(overlay)
        assert.equals(tmp .. "/overlays/demo/data", overlay.data_root)
        assert.truthy(lfs.attributes(overlay.data_root, "mode"))
      end)
    end)
  end)

  describe("items + append + replace + delete", function()
    local base = {
      { id = "1", title = "First" },
      { id = "2", title = "Second" },
    }

    it("replays the base when no mutations", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        assert.are_same(base, overlay:items("notes", base))
      end)
    end)

    it("appends an item with an explicit id and assigns positional ids otherwise", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")

        local id1 = overlay:append("notes", base, { id = "x", title = "X" })
        assert.equals("x", id1)
        local id2 = overlay:append("notes", base, { title = "Y" })
        -- base has 2 items; first append is #3; second append's positional id is #4
        assert.equals("4", id2)

        local items = overlay:items("notes", base)
        assert.equals(4, #items)
        assert.equals("X", items[3].title)
        assert.equals("Y", items[4].title)
      end)
    end)

    it("rejects a duplicate explicit id with conflict", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        local id, ekind = overlay:append("notes", base, { id = "1", title = "Dupe" })
        assert.is_nil(id)
        assert.equals("conflict", ekind)
      end)
    end)

    it("replaces an item and reflects on the next read", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        local ok = overlay:replace("notes", base, "1", { id = "1", title = "Updated" })
        assert.is_true(ok)

        local items = overlay:items("notes", base)
        assert.equals("Updated", items[1].title)
      end)
    end)

    it("rejects replace on a body id that doesn't match the path id", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        local ok, ekind = overlay:replace("notes", base, "1", { id = "2", title = "Swap" })
        assert.is_nil(ok)
        assert.equals("conflict", ekind)
      end)
    end)

    it("deletes an item and the merged view reflects it", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        local ok = overlay:delete("notes", base, "1")
        assert.is_true(ok)

        local items = overlay:items("notes", base)
        assert.equals(1, #items)
        assert.equals("2", items[1].id)
      end)
    end)

    it("rejects delete on an unknown id", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        local ok, ekind = overlay:delete("notes", base, "999")
        assert.is_nil(ok)
        assert.equals("not_found", ekind)
      end)
    end)

    it("persists the op log across new Overlay instances", function()
      with_tmpdir(function(tmp)
        local overlay1 = Overlay.new(tmp, "demo")
        overlay1:append("notes", base, { id = "persisted", title = "P" })

        local overlay2 = Overlay.new(tmp, "demo")
        local items = overlay2:items("notes", base)
        local found = false
        for _, item in ipairs(items) do
          if item.id == "persisted" then found = true break end
        end
        assert.is_true(found)
      end)
    end)
  end)

  describe("item (read)", function()
    local base = { { id = "1", title = "First" } }

    it("returns the item for an existing id", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        local item = overlay:item("notes", base, "1")
        assert.same({ id = "1", title = "First" }, item)
      end)
    end)

    it("returns not_found for an unknown id", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        local item, ekind = overlay:item("notes", base, "999")
        assert.is_nil(item)
        assert.equals("not_found", ekind)
      end)
    end)
  end)

  describe("writable guard", function()
    it("returns true when metadata has no readOnly", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        assert.is_true(overlay:writable({}))
        assert.is_true(overlay:writable(nil))
      end)
    end)

    it("returns false when metadata.readOnly == true", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        assert.is_false(overlay:writable({ readOnly = true }))
      end)
    end)
  end)

  describe("safe name enforcement", function()
    it("rejects path traversal in dataset names", function()
      with_tmpdir(function(tmp)
        local overlay = Overlay.new(tmp, "demo")
        local path, err = overlay:ops_path("../escape")
        assert.is_nil(path)
        assert.is_truthy(err:match("unsafe"))
      end)
    end)
  end)
end)
