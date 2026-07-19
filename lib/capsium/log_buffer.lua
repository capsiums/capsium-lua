-- Capsium Lua Library
-- Log ring buffer (framework-agnostic)
--
-- Port of the Ruby gem's Capsium::LogBuffer (0.4.0 parity): a small ring
-- buffer of timestamped log entries with a fixed capacity — when full,
-- the oldest entry is dropped. The reactor records key serving events
-- here and exposes the most recent lines through the per-package
-- /package/<name>/logs introspection endpoint (07-reactor).

local utils = require "capsium.utils"

local _M = {
  _VERSION = "0.4.0"
}
local _M_mt = { __index = _M }

local DEFAULT_CAPACITY = 500

-- Create a ring buffer.
--   opts.capacity (optional, default 500): maximum retained entries
-- Returns buffer | nil, err.
function _M.new(opts)
  opts = opts or {}
  local capacity = opts.capacity or DEFAULT_CAPACITY
  if capacity < 1 then
    return nil, "capacity must be at least 1"
  end

  return setmetatable({
    capacity = capacity,
    entries = {} -- array of { timestamp, message }, oldest first
  }, _M_mt)
end

-- Append a message (timestamp in epoch seconds, default now).
function _M:add(message, timestamp)
  if #self.entries >= self.capacity then
    table.remove(self.entries, 1)
  end
  table.insert(self.entries, {
    timestamp = timestamp or os.time(),
    message = message
  })
  return self
end

-- The last count entries, oldest first.
function _M:last(count)
  local n = math.min(count, #self.entries)
  local out = {}
  for i = #self.entries - n + 1, #self.entries do
    table.insert(out, self.entries[i])
  end
  return out
end

-- The last count entries as formatted lines, oldest first:
-- "2026-07-19T15:00:00Z message"
function _M:lines(count)
  local out = {}
  for _, entry in ipairs(self:last(count)) do
    table.insert(out, utils.format_timestamp(entry.timestamp) .. " " ..
                 entry.message)
  end
  return out
end

return _M
