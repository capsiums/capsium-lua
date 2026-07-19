-- Capsium Lua Library
-- Route-level access control evaluation (ARCHITECTURE.md section 4b)
--
-- Dataset-route accessControl is enforced AFTER authentication:
--   authenticationRequired == true  -> 401 when unauthenticated
--   roles = [...]                   -> 403 unless the principal has one
-- With basic auth the principal carries no roles (htpasswd has none), so
-- any roles requirement fails closed (403); documented in README.

local _M = {
  _VERSION = "0.4.0"
}

-- Evaluate a route's accessControl against a principal.
--   access_control: nil | { authenticationRequired = bool, roles = {...} }
--   principal: nil | { subject = ..., roles = {...} }
-- Returns "allow" | "unauthenticated" (401) | "forbidden" (403).
function _M.evaluate(access_control, principal)
  if type(access_control) ~= "table" then
    return "allow"
  end

  if access_control.authenticationRequired == true and not principal then
    return "unauthenticated"
  end

  local roles = access_control.roles
  if type(roles) == "table" and #roles > 0 then
    local principal_roles = principal and principal.roles or {}
    for _, required in ipairs(roles) do
      for _, held in ipairs(principal_roles) do
        if required == held then
          return "allow"
        end
      end
    end
    return "forbidden"
  end

  return "allow"
end

return _M
