-- Writable overlay for a Capsium mount (CC 62001 §05x-storage +
-- m-writable-packages). Mirrors the Ruby reactor's overlay shape:
-- an append-only JSON operation log per dataset, replayed over the
-- base collection on every read. The base .cap on disk never
-- changes; writes go to the workdir.
--
-- Public API:
--   Overlay.new(workdir, package_name) → overlay
--   overlay:items(dataset)             → merged array
--   overlay:item(dataset, id)          → item | nil, err
--   overlay:append(dataset, item)      → id | nil, err, err_kind
--   overlay:replace(dataset, id, item) → true | nil, err, err_kind
--   overlay:delete(dataset, id)        → true | nil, err, err_kind
--   overlay:writable?(metadata)        → bool (true unless readOnly == true)
--
-- Op log shape (matches Ruby; cross-reactor consistent):
--   { op = "append"|"replace"|"delete", item = ..., id = ... }

local M = {}

local cjson = require "cjson"
local utils = require "capsium.utils"

-- Item id convention: explicit "id" field, else nil (positional).
local function item_id(item)
  if type(item) == "table" and item.id ~= nil then
    return tostring(item.id)
  end
  return nil
end

-- Positional ids are 1-based index as a string and only match items
-- without an explicit "id" field.
local function find_index(items, id)
  for i, item in ipairs(items) do
    if item_id(item) == id then return i end
  end
  if not (string.match(tostring(id), "^%d+$")) then return nil end
  local index = tonumber(id)
  if index < 1 then return nil end
  local item = items[index]
  if item and item_id(item) == nil then return index end
  return nil
end

local function safe_name(name)
  return type(name) == "string" and string.match(name, "^[%w%.%-]+$") == name
end

function M.new(workdir, package_name)
  if type(workdir) ~= "string" or type(package_name) ~= "string" then
    return nil, "Overlay requires workdir + package_name strings"
  end

  local root = workdir .. "/overlays/" .. package_name
  local data_root = root .. "/data"
  local ok = utils.mkdir_p(data_root)
  if not ok then
    return nil, "Overlay cannot create workdir at " .. data_root
  end

  return setmetatable({
    root = root,
    data_root = data_root,
    package_name = package_name,
    _cache = {},
  }, { __index = M })
end

-- Whether the mount is writable. Metadata carries the readOnly flag;
-- the overlay itself is always available — writability is gated by
-- the caller based on package metadata.
function M:writable(metadata)
  return not (metadata and metadata.readOnly == true)
end

-- Returns the on-disk path to a dataset's op log. nil + err when the
-- name is unsafe (path-traversal guard).
function M:ops_path(name)
  if not safe_name(name) then
    return nil, "unsafe dataset name for the overlay: " .. tostring(name)
  end
  return self.data_root .. "/" .. name .. ".json"
end

-- Loads and caches the op log for a dataset. Returns the log array
-- (possibly empty). Cache is per-overlay-instance; restart re-reads.
function M:ops(name)
  if self._cache[name] then return self._cache[name] end
  local path, err = self:ops_path(name)
  if not path then return {}, err end

  local file = io.open(path, "r")
  if not file then
    self._cache[name] = {}
    return self._cache[name]
  end
  local content = file:read("*a")
  file:close()
  local ok, parsed = pcall(cjson.decode, content)
  self._cache[name] = ok and parsed or {}
  return self._cache[name]
end

-- Persists the op log for a dataset to disk. Atomic via tmp + rename.
function M:persist(name)
  local log = self._cache[name]
  if not log then return true end
  local path, err = self:ops_path(name)
  if not path then return nil, err end

  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if not file then return nil, "cannot write overlay log: " .. path end
  file:write(cjson.encode(log))
  file:close()
  os.rename(tmp, path)
  return true
end

-- Appends an op record to the log and persists.
function M:record(name, op_record)
  local log = self:ops(name)
  log[#log + 1] = op_record
  return self:persist(name)
end

-- Applies a single op record to a working items list, returning the
-- new list. Skips ops whose addressed id is no longer present (base
-- changed underneath — defensive).
local function apply_op(items, record)
  if record.op == "append" then
    items[#items + 1] = record.item
    return items
  end
  local index = find_index(items, record.id)
  if not index then return items end

  if record.op == "replace" then
    items[index] = record.item
  elseif record.op == "delete" then
    table.remove(items, index)
  end
  return items
end

-- Replays the op log over a base collection, producing the merged
-- items array. Caller supplies the base (read from the .cap dataset).
function M:replay(name, base)
  local log = self:ops(name)
  if #log == 0 then return base end

  local items = {}
  for _, item in ipairs(base or {}) do items[#items + 1] = item end
  for _, record in ipairs(log) do
    items = apply_op(items, record)
  end
  return items
end

-- Returns the merged items array for a dataset.
function M:items(name, base)
  return self:replay(name, base or {})
end

-- Returns the item at id, or nil + err_kind ("not_found").
function M:item(name, base, id)
  local items = self:items(name, base)
  local index = find_index(items, id)
  if not index then
    return nil, "not_found", "no item " .. tostring(id) .. " in dataset " .. name
  end
  return items[index]
end

-- Appends an item; returns the new id. Errors: "conflict" on duplicate
-- explicit id, "bad_item" when not a table.
function M:append(name, base, item)
  if type(item) ~= "table" then
    return nil, "bad_item", "item body must be a JSON object"
  end

  local items = self:items(name, base)
  local explicit = item_id(item)
  if explicit and find_index(items, explicit) then
    return nil, "conflict", "item id " .. explicit .. " already exists in " .. name
  end

  self:record(name, { op = "append", item = item })
  if explicit then return explicit end
  return tostring(#items + 1)
end

-- Replaces an item at id. Errors: "not_found", "conflict" on id mismatch.
function M:replace(name, base, id, item)
  if type(item) ~= "table" then
    return nil, "bad_item", "item body must be a JSON object"
  end

  local items = self:items(name, base)
  if not find_index(items, id) then
    return nil, "not_found", "no item " .. tostring(id) .. " in dataset " .. name
  end

  local explicit = item_id(item)
  if explicit and explicit ~= tostring(id) then
    return nil, "conflict", "body id " .. explicit .. " does not match " .. tostring(id)
  end

  self:record(name, { op = "replace", id = tostring(id), item = item })
  return true
end

-- Deletes the item at id. Errors: "not_found".
function M:delete(name, base, id)
  local items = self:items(name, base)
  if not find_index(items, id) then
    return nil, "not_found", "no item " .. tostring(id) .. " in dataset " .. name
  end

  self:record(name, { op = "delete", id = tostring(id) })
  return true
end

return M
