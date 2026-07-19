describe("Capsium hash adapter", function()
  local hash = require "capsium.adapters.hash"

  it("reports an active backend", function()
    local backend = hash.backend()
    assert.is_string(backend)
    assert.is_truthy(backend == "resty" or backend:match("^pure%-lua:"))
  end)

  describe("sha256_hex known-answer vectors", function()
    it("hashes the empty string", function()
      assert.equals(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hash.sha256_hex(""))
    end)

    it("hashes 'abc'", function()
      assert.equals(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        hash.sha256_hex("abc"))
    end)

    it("hashes a 56-byte message (padding boundary)", function()
      assert.equals(
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        hash.sha256_hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
    end)

    it("hashes a 1,000,000 character message", function()
      assert.equals(
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
        hash.sha256_hex(string.rep("a", 1000000)))
    end)

    it("hashes binary data", function()
      local bin = string.char(0, 1, 2, 3, 255, 254, 253)
      local hex = hash.sha256_hex(bin)
      assert.equals(64, #hex)
      assert.is_truthy(hex:match("^[0-9a-f]+$"))
    end)
  end)

  describe("sha256_file_hex", function()
    it("hashes a file on disk", function()
      local path = os.tmpname()
      local f = assert(io.open(path, "wb"))
      f:write("abc")
      f:close()

      local hex, err = hash.sha256_file_hex(path)
      os.remove(path)

      assert.is_nil(err)
      assert.equals(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        hex)
    end)

    it("returns nil, err for a missing file", function()
      local hex, err = hash.sha256_file_hex("no-such-file-12345.bin")
      assert.is_nil(hex)
      assert.is_string(err)
    end)
  end)
end)
