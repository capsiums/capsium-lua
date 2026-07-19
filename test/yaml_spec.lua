describe("capsium.yaml (minimal block-style parser)", function()
  local yaml = require "capsium.yaml"

  it("parses flat mappings with scalar coercion", function()
    local data = assert(yaml.parse(table.concat({
      "name: Lion",
      "legs: 4",
      "weight: 190.5",
      "wild: true",
      "domestic: false",
      "nickname: ~",
      "quoted: \"with space\"",
      "single: 'it''s'"
    }, "\n")))

    assert.equals("Lion", data.name)
    assert.equals(4, data.legs)
    assert.equals(190.5, data.weight)
    assert.is_true(data.wild)
    assert.is_false(data.domestic)
    assert.is_nil(data.nickname)
    assert.equals("with space", data.quoted)
    assert.equals("it's", data.single)
  end)

  it("parses nested mappings and sequences of scalars", function()
    local data = assert(yaml.parse(table.concat({
      "meta:",
      "  title: animals",
      "  count: 3",
      "tags:",
      "  - wild",
      "  - 5",
      "  - \"quoted\""
    }, "\n")))

    assert.equals("animals", data.meta.title)
    assert.equals(3, data.meta.count)
    assert.same({ "wild", 5, "quoted" }, data.tags)
  end)

  it("parses sequences of mappings (dataset documents)", function()
    local data = assert(yaml.parse(table.concat({
      "categories:",
      "  - id: 1",
      "    name: \"Mammals\"",
      "  - id: 2",
      "    name: \"Birds\"",
      "animals:",
      "  - name: \"Lion\"",
      "    category_id: 1",
      "  - name: \"Eagle\"",
      "    category_id: 2"
    }, "\n")))

    assert.equals(2, #data.categories)
    assert.equals(1, data.categories[1].id)
    assert.equals("Mammals", data.categories[1].name)
    assert.equals("Birds", data.categories[2].name)
    assert.equals("Lion", data.animals[1].name)
    assert.equals(2, data.animals[2].category_id)
  end)

  it("handles comments, blank lines and document markers", function()
    local data = assert(yaml.parse(table.concat({
      "---",
      "# a comment",
      "name: Lion # trailing comment",
      "",
      "quoted: \"# not a comment\""
    }, "\n")))

    assert.equals("Lion", data.name)
    assert.equals("# not a comment", data.quoted)
  end)

  it("parses double-quoted escapes", function()
    local data = assert(yaml.parse('text: "line\\nbreak\\t\\"quoted\\""'))
    assert.equals('line\nbreak\t"quoted"', data.text)
  end)

  it("errors on unsupported or malformed input", function()
    -- Flow collections are out of the subset: a "- [...]" line reads as
    -- a plain scalar (documented limitation)
    local flow = assert(yaml.parse("- [flow, sequence]"))
    assert.same({ "[flow, sequence]" }, flow)

    assert.is_nil(yaml.parse("key: value\n  stray: indent"))
    assert.is_nil(yaml.parse("\ttabbed: true"))
    assert.is_nil(yaml.parse(""))
    assert.is_nil(yaml.parse(nil))
  end)
end)
