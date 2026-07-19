-- capsium-lua Composite Package Helpers
-- Dependency resource references and section-4a route inheritance
-- processing (framework-agnostic, pure functions)
--
-- Dependency resource references are "<dependency-guid>/<package-relative
-- path>": any route resource containing "://" whose longest matching
-- dependency-guid prefix addresses a resource of that dependency, e.g.
-- with dependency guid "https://example.com/core", the reference
-- "https://example.com/core/content/app.js" addresses content/app.js of
-- that package. When several dependency guids prefix-match, the longest
-- guid wins (mirrors the Ruby reactor's MergedView and @capsium/core
-- composite.ts).

local _M = {
  _VERSION = "0.4.0"
}

-- True when `resource` is a dependency reference (a "<guid>/<path>" URI).
function _M.is_dependency_ref(resource)
  return type(resource) == "string" and resource:find("://") ~= nil
end

-- Parse a resource reference against the known dependency guids (longest
-- guid prefix wins). Returns { guid, path } | nil.
function _M.parse_ref(resource, dependency_guids)
  if not _M.is_dependency_ref(resource) then
    return nil
  end

  local best = nil

  for _, guid in ipairs(dependency_guids or {}) do
    if type(guid) == "string"
       and resource:sub(1, #guid + 1) == guid .. "/"
       and #resource > #guid + 1 then
      if not best or #guid > #best.guid then
        best = { guid = guid, path = resource:sub(#guid + 2) }
      end
    end
  end

  return best
end

local function find_header(headers, name)
  local lower = name:lower()
  for key in pairs(headers) do
    if key:lower() == lower then
      return key
    end
  end
  return nil
end

-- Apply section-4a route inheritance processing to a resolved static
-- target (mirrors swsws applyResponseProcessing):
--   responseHeaders        ADDED only when absent (case-insensitive)
--   responseRewrite.headers OVERRIDE existing headers
--   responseRewrite.body   REPLACES the served body
-- requestHeaders supplant the request only when forwarding to dynamic
-- handlers, which this reactor does not execute (accepted and ignored
-- for static resources).
--   target: { headers = <from route.headers>, ... } (mutated)
--   route:  the normalized route entry
-- Returns the target.
function _M.apply_response_processing(target, route)
  target.headers = target.headers or {}

  if type(route.responseHeaders) == "table" then
    for name, value in pairs(route.responseHeaders) do
      if not find_header(target.headers, name) then
        target.headers[name] = value
      end
    end
  end

  local rewrite = route.responseRewrite
  if type(rewrite) == "table" then
    if type(rewrite.headers) == "table" then
      for name, value in pairs(rewrite.headers) do
        local existing = find_header(target.headers, name)
        if existing and existing ~= name then
          target.headers[existing] = nil
        end
        target.headers[name] = value
      end
    end

    if type(rewrite.body) == "string" then
      target.body = rewrite.body
      target.path = nil -- the rewritten body replaces the file content
    end
  end

  return target
end

return _M
