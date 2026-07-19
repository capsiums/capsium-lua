describe("Capsium log buffer (per-worker ring buffer)", function()
  local LogBuffer = require "capsium.log_buffer"

  it("requires a capacity of at least 1", function()
    local buffer, err = LogBuffer.new({ capacity = 0 })
    assert.is_nil(buffer)
    assert.matches("capacity must be at least 1", err)
  end)

  it("appends and returns entries oldest first", function()
    local buffer = assert(LogBuffer.new())
    buffer:add("first", 1000)
    buffer:add("second", 2000)

    local entries = buffer:last(10)
    assert.equals(2, #entries)
    assert.equals("first", entries[1].message)
    assert.equals("second", entries[2].message)
    assert.equals(1000, entries[1].timestamp)
  end)

  it("drops the oldest entry when full", function()
    local buffer = assert(LogBuffer.new({ capacity = 3 }))
    for i = 1, 5 do
      buffer:add("line " .. i, i)
    end

    local entries = buffer:last(10)
    assert.equals(3, #entries)
    assert.equals("line 3", entries[1].message)
    assert.equals("line 5", entries[3].message)
  end)

  it("returns only the requested tail", function()
    local buffer = assert(LogBuffer.new({ capacity = 10 }))
    for i = 1, 5 do
      buffer:add("line " .. i, i)
    end

    local entries = buffer:last(2)
    assert.equals(2, #entries)
    assert.equals("line 4", entries[1].message)
    assert.equals("line 5", entries[2].message)
  end)

  it("formats lines as ISO8601 + message", function()
    local buffer = assert(LogBuffer.new())
    buffer:add("GET /app/ -> 200", 1784474400) -- 2026-07-19T15:20:00Z

    local lines = buffer:lines(100)
    assert.equals(1, #lines)
    assert.equals("2026-07-19T15:20:00Z GET /app/ -> 200", lines[1])
  end)

  it("is empty before anything is logged", function()
    local buffer = assert(LogBuffer.new())
    assert.same({}, buffer:last(100))
    assert.same({}, buffer:lines(100))
  end)
end)
