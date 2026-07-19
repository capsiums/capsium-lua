describe("Capsium CSV parser", function()
  local csv = require "capsium.csv"

  it("parses simple rows", function()
    local rows = csv.parse("a,b,c\n1,2,3\n")
    assert.are_same({ { "a", "b", "c" }, { "1", "2", "3" } }, rows)
  end)

  it("handles CRLF line endings", function()
    local rows = csv.parse("a,b\r\n1,2\r\n")
    assert.are_same({ { "a", "b" }, { "1", "2" } }, rows)
  end)

  it("handles quoted fields with commas and quotes", function()
    local rows = csv.parse('name,desc\n"x,y","say ""hi"""\n')
    assert.are_same({ { "name", "desc" }, { "x,y", 'say "hi"' } }, rows)
  end)

  it("handles newlines inside quoted fields", function()
    local rows = csv.parse('a,b\n"line1\nline2",z\n')
    assert.are_same({ { "a", "b" }, { "line1\nline2", "z" } }, rows)
  end)

  it("handles input without a trailing newline", function()
    local rows = csv.parse("a,b\n1,2")
    assert.are_same({ { "a", "b" }, { "1", "2" } }, rows)
  end)

  it("returns nil, err for unterminated quotes", function()
    local rows, err = csv.parse('a,b\n"oops,2\n')
    assert.is_nil(rows)
    assert.is_string(err)
  end)

  it("returns nil, err for non-string input", function()
    local rows, err = csv.parse(nil)
    assert.is_nil(rows)
    assert.is_string(err)
  end)

  describe("to_objects", function()
    it("maps rows to header keys", function()
      local objects = csv.to_objects("name,legs\ncat,4\nspider,8\n")
      assert.are_same({
        { name = "cat", legs = "4" },
        { name = "spider", legs = "8" }
      }, objects)
    end)

    it("returns an empty array for empty input", function()
      assert.are_same({}, csv.to_objects(""))
    end)
  end)
end)
