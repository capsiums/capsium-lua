-- REST CRUD over a mount's datasets (CC 62001 §05x-storage +
-- m-writable-packages). Mirrors the Ruby reactor's DataApi shape:
-- collection routes support GET (list) + POST (append); item routes
-- support GET (read) + PUT (replace) + DELETE. Writes go through the
-- mount's Overlay (one op log per dataset); reads consult the overlay
-- first then fall through to the base.
--
-- Returns true when handled (the caller must NOT also write a
-- response), false when the path wasn't a data API path, or nil +
-- error when the handler hit an internal error.

local M = {}

local cjson = require "cjson"

local PREFIX = "/api/v1/data/"
local COLLECTION_PATTERN = "^/api/v1/data/([^/]+)$"
local ITEM_PATTERN = "^/api/v1/data/([^/]+)/([^/]+)$"

function M.is_path(inner_path)
  return inner_path:sub(1, #PREFIX) == PREFIX
end

-- Resolves the dataset name + optional id from an inner_path. Returns
-- nil if the path doesn't address a dataset route the package serves.
function M.parse(inner_path)
  local dataset, id = inner_path:match(ITEM_PATTERN)
  if dataset then return dataset, id end

  dataset = inner_path:match(COLLECTION_PATTERN)
  if dataset then return dataset, nil end

  return nil
end

local function respond_json(status, body)
  ngx.status = status
  ngx.header.content_type = "application/json"
  ngx.say(cjson.encode(body))
end

local function respond_error(status, message)
  ngx.status = status
  ngx.header.content_type = "application/json"
  ngx.say(cjson.encode({ error = message }))
end

local function method_not_allowed(allow)
  ngx.status = ngx.HTTP_METHOD_NOT_ALLOWED
  ngx.header["Allow"] = allow
  respond_error(ngx.HTTP_METHOD_NOT_ALLOWED, "Method not allowed; supported: " .. allow)
end

local function parse_body()
  ngx.req.read_body()
  local raw = ngx.req.get_body_data()
  if not raw then return nil, "request body is empty" end

  local ok, parsed = pcall(cjson.decode, raw)
  if not ok then return nil, "invalid JSON body: " .. tostring(parsed) end
  if parsed == cjson.null then return nil, "request body must not be null" end
  return parsed
end

-- Mounts: the caller supplies the mount's overlay (lazily created),
-- the base dataset loader, and the package metadata so we can check
-- readOnly. Returns the HTTP status code; the caller can log metrics.
function M.handle(args)
  local inner_path = args.inner_path
  local method = args.method
  local dataset_name = args.dataset_name
  local id = args.id
  local overlay = args.overlay
  local load_base = args.load_base

  -- Read base collection through the caller's loader.
  local base, derr, dkind = load_base(dataset_name)
  if not base then
    local status = (dkind == "not_implemented") and
                    ngx.HTTP_NOT_IMPLEMENTED or
                    ngx.HTTP_INTERNAL_SERVER_ERROR
    respond_error(status, tostring(derr))
    return status
  end

  -- Collection operations: GET, POST.
  if not id then
    if method == "GET" then
      respond_json(ngx.HTTP_OK, overlay:items(dataset_name, base))
      return ngx.HTTP_OK
    end

    if method == "POST" then
      local item, perr = parse_body()
      if not item then
        respond_error(ngx.HTTP_BAD_REQUEST, perr)
        return ngx.HTTP_BAD_REQUEST
      end

      local new_id, ekind, emsg = overlay:append(dataset_name, base, item)
      if not new_id then
        local status = (ekind == "conflict") and ngx.HTTP_CONFLICT or
                       (ekind == "bad_item") and ngx.HTTP_UNPROCESSABLE_ENTITY or
                       ngx.HTTP_INTERNAL_SERVER_ERROR
        respond_error(status, emsg)
        return status
      end

      ngx.status = ngx.HTTP_CREATED
      ngx.header["Location"] = inner_path .. "/" .. new_id
      ngx.header.content_type = "application/json"
      ngx.say(cjson.encode(item))
      return ngx.HTTP_CREATED
    end

    return method_not_allowed("GET, POST")
  end

  -- Item operations: GET, PUT, DELETE.
  if method == "GET" then
    local item, ekind, emsg = overlay:item(dataset_name, base, id)
    if not item then
      respond_error(ngx.HTTP_NOT_FOUND, emsg or "no item " .. id)
      return ngx.HTTP_NOT_FOUND
    end
    respond_json(ngx.HTTP_OK, item)
    return ngx.HTTP_OK
  end

  if method == "PUT" then
    local item, perr = parse_body()
    if not item then
      respond_error(ngx.HTTP_BAD_REQUEST, perr)
      return ngx.HTTP_BAD_REQUEST
    end

    local ok, ekind, emsg = overlay:replace(dataset_name, base, id, item)
    if not ok then
      local status = (ekind == "not_found") and ngx.HTTP_NOT_FOUND or
                     (ekind == "conflict") and ngx.HTTP_CONFLICT or
                     (ekind == "bad_item") and ngx.HTTP_UNPROCESSABLE_ENTITY or
                     ngx.HTTP_INTERNAL_SERVER_ERROR
      respond_error(status, emsg)
      return status
    end

    respond_json(ngx.HTTP_OK, item)
    return ngx.HTTP_OK
  end

  if method == "DELETE" then
    local ok, ekind, emsg = overlay:delete(dataset_name, base, id)
    if not ok then
      local status = (ekind == "not_found") and ngx.HTTP_NOT_FOUND or
                     ngx.HTTP_INTERNAL_SERVER_ERROR
      respond_error(status, emsg)
      return status
    end

    ngx.status = ngx.HTTP_NO_CONTENT
    return ngx.HTTP_NO_CONTENT
  end

  return method_not_allowed("GET, PUT, DELETE")
end

return M
