describe("Capsium MIME detection", function()
  local mime = require "capsium.mime"

  it("maps common extensions", function()
    assert.equals("text/html", mime.type_for("index.html"))
    assert.equals("text/html", mime.type_for("page.htm"))
    assert.equals("text/css", mime.type_for("styles.css"))
    assert.equals("application/json", mime.type_for("data.json"))
    assert.equals("application/xml", mime.type_for("documents.xml"))
    assert.equals("image/png", mime.type_for("logo.png"))
    assert.equals("application/pdf", mime.type_for("doc.pdf"))
  end)

  it("maps JavaScript to text/javascript (RFC 9239)", function()
    assert.equals("text/javascript", mime.type_for("app.js"))
    assert.equals("text/javascript", mime.type_for("app.mjs"))
  end)

  it("is case-insensitive", function()
    assert.equals("text/html", mime.type_for("INDEX.HTML"))
    assert.equals("image/jpeg", mime.type_for("photo.JPG"))
  end)

  it("maps the .cap package extension", function()
    assert.equals("application/vnd.capsium.package",
                  mime.type_for("pkg-1.0.0.cap"))
  end)

  it("returns nil for unknown extensions and invalid input", function()
    assert.is_nil(mime.type_for("archive.xyz"))
    assert.is_nil(mime.type_for("no-extension"))
    assert.is_nil(mime.type_for(nil))
  end)
end)
