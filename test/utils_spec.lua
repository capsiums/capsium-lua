describe("Capsium Utils", function()
  local utils = require "capsium.utils"

  describe("format_timestamp", function()
    it("formats Unix timestamp to ISO 8601", function()
      local timestamp = 1609459200 -- 2021-01-01 00:00:00 UTC
      local formatted = utils.format_timestamp(timestamp)

      assert.equals("2021-01-01T00:00:00Z", formatted)
    end)
  end)

  describe("deep_copy", function()
    it("creates a deep copy of a table", function()
      local original = {
        a = 1,
        b = { c = 2, d = 3 },
        e = { f = { g = 4 } }
      }

      local copy = utils.deep_copy(original)

      -- Modify copy
      copy.a = 10
      copy.b.c = 20
      copy.e.f.g = 40

      -- Original should be unchanged
      assert.equals(1, original.a)
      assert.equals(2, original.b.c)
      assert.equals(4, original.e.f.g)
    end)
  end)

  describe("merge_tables", function()
    it("merges two tables", function()
      local t1 = { a = 1, b = 2, c = { d = 3 } }
      local t2 = { b = 20, c = { e = 30 }, f = 40 }

      local result = utils.merge_tables(t1, t2)

      assert.equals(1, result.a)
      assert.equals(20, result.b)
      assert.equals(3, result.c.d)
      assert.equals(30, result.c.e)
      assert.equals(40, result.f)
    end)
  end)

  describe("url_encode", function()
    it("encodes URL strings correctly", function()
      assert.equals("hello+world", utils.url_encode("hello world"))
      assert.equals("test%40example.com", utils.url_encode("test@example.com"))
      assert.equals("path%2Fto%2Ffile", utils.url_encode("path/to/file"))
    end)
  end)

  describe("url_decode", function()
    it("decodes URL strings correctly", function()
      assert.equals("hello world", utils.url_decode("hello+world"))
      assert.equals("test@example.com", utils.url_decode("test%40example.com"))
      assert.equals("path/to/file", utils.url_decode("path%2Fto%2Ffile"))
    end)
  end)

  describe("file_exists", function()
    it("returns true for existing files", function()
      -- .busted file should exist
      assert.is_true(utils.file_exists(".busted"))
    end)

    it("returns false for non-existent files", function()
      assert.is_false(utils.file_exists("nonexistent-file.txt"))
    end)
  end)

  describe("dir_exists", function()
    it("returns true for existing directories", function()
      assert.is_true(utils.dir_exists("lib"))
      assert.is_true(utils.dir_exists("test"))
    end)

    it("returns false for non-existent directories", function()
      assert.is_false(utils.dir_exists("nonexistent-directory"))
    end)
  end)
end)
