-- Capsium Lua Library
-- HTTP Basic authentication (ARCHITECTURE.md section 4b)
--
-- Parses the Authorization header and verifies credentials against an
-- htpasswd file. Framework-agnostic: the caller supplies header value
-- and file content.

local utils = require "capsium.utils"
local htpasswd = require "capsium.auth.htpasswd"

local _M = {
  _VERSION = "0.4.0"
}

-- Check an Authorization header value against htpasswd content.
--   deploy_roles: optional deploy-time role assignments keyed by username
--     ({ "alice" = { "admin", ... } }); htpasswd itself carries no role
--     concept, so roles come from the deployment (section 4b).
-- Returns principal { subject = username, roles = {...}, method = "basic" }
-- or nil (missing/malformed header or invalid credentials).
function _M.authenticate(header, htpasswd_content, deploy_roles)
  if type(header) ~= "string" then
    return nil
  end

  local encoded = header:match("^[Bb]asic%s+(.+)$")
  if not encoded then
    return nil
  end

  local decoded = utils.base64_decode(encoded)
  if not decoded then
    return nil
  end

  local username, password = decoded:match("^([^:]*):(.*)$")
  if not username then
    return nil
  end

  if not htpasswd.verify(htpasswd_content, username, password) then
    return nil
  end

  local roles = {}
  if type(deploy_roles) == "table" and type(deploy_roles[username]) == "table"
  then
    for _, role in ipairs(deploy_roles[username]) do
      if type(role) == "string" then
        roles[#roles + 1] = role
      end
    end
  end

  return {
    subject = username,
    roles = roles,
    method = "basic"
  }
end

return _M
