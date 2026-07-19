-- Capsium Lua Library
-- OAuth2 authorization-code flow with PKCE (ARCHITECTURE.md section 4b)
--
-- Pure flow logic against configurable endpoints; the HTTP calls are
-- injected (the ngx glue wires resty.http, unit tests use stubs). The
-- client secret comes from the reactor deploy config, never from the
-- package. The state value and the PKCE verifier travel in a signed
-- short-lived cookie (capsium.auth.session), so the flow survives
-- multi-worker deployments without server-side state.

local utils = require "capsium.utils"
local session = require "capsium.auth.session"

local _M = {
  _VERSION = "0.3.0"
}

-- ---------------------------------------------------------------------------
-- Randomness + PKCE
-- ---------------------------------------------------------------------------

-- Random URL-safe string (32 random bytes, base64url).
function _M.random_token()
  require "resty.openssl.version"
  local rand = require "resty.openssl.rand"

  local bytes = assert(rand.bytes(32))
  return session.base64url_encode(bytes)
end

-- New PKCE pair: { verifier, challenge } (S256).
function _M.new_pkce()
  local verifier = _M.random_token()

  require "resty.openssl.version"
  local digest = require "resty.openssl.digest"
  local ctx = assert(digest.new("sha256"))
  ctx:update(verifier)

  return {
    verifier = verifier,
    challenge = session.base64url_encode(ctx:final())
  }
end

-- ---------------------------------------------------------------------------
-- Authorization redirect (front channel)
-- ---------------------------------------------------------------------------

-- Build the authorization URL the user's browser is redirected to.
--   config: the package's normalized oauth2 config (client_id,
--     authorization_url, scopes, redirect_path)
--   redirect_uri: absolute callback URI (scheme://host<mount><redirectPath>)
--   state: opaque state value
--   challenge: PKCE S256 challenge
function _M.authorization_url(config, redirect_uri, state, challenge)
  local params = {
    "response_type=code",
    "client_id=" .. utils.url_encode(config.client_id),
    "redirect_uri=" .. utils.url_encode(redirect_uri),
    "state=" .. utils.url_encode(state),
    "code_challenge=" .. utils.url_encode(challenge),
    "code_challenge_method=S256"
  }

  local scopes = config.scopes
  if type(scopes) == "table" and #scopes > 0 then
    params[#params + 1] = "scope=" ..
      utils.url_encode(table.concat(scopes, " "))
  end

  local separator = config.authorization_url:find("?", 1, true) and "&"
                    or "?"
  return config.authorization_url .. separator .. table.concat(params, "&")
end

-- ---------------------------------------------------------------------------
-- Token exchange (back channel; http_post injected)
-- ---------------------------------------------------------------------------

-- Exchange an authorization code for tokens.
--   http_post(url, headers, body) -> status, response_body
-- Returns token table | nil, err.
function _M.exchange_code(config, code, verifier, redirect_uri, http_post)
  local body_params = {
    "grant_type=authorization_code",
    "code=" .. utils.url_encode(code),
    "redirect_uri=" .. utils.url_encode(redirect_uri),
    "client_id=" .. utils.url_encode(config.client_id),
    "code_verifier=" .. utils.url_encode(verifier)
  }
  if config.client_secret then
    body_params[#body_params + 1] = "client_secret=" ..
      utils.url_encode(config.client_secret)
  end

  local status, response_body = http_post(config.token_url, {
    ["Content-Type"] = "application/x-www-form-urlencoded",
    ["Accept"] = "application/json"
  }, table.concat(body_params, "&"))

  if not status or status < 200 or status >= 300 then
    return nil, "token endpoint returned " .. tostring(status)
  end

  local cjson = require "cjson"
  local ok, tokens = pcall(cjson.decode, response_body or "")
  if not ok or type(tokens) ~= "table"
     or type(tokens.access_token) ~= "string" then
    return nil, "token endpoint did not return an access_token"
  end

  return tokens
end

-- Fetch the userinfo resource (http_get injected).
--   http_get(url, headers) -> status, response_body
-- Returns userinfo table | nil, err.
function _M.fetch_userinfo(config, access_token, http_get)
  if not config.userinfo_url then
    return {}
  end

  local status, body = http_get(config.userinfo_url, {
    ["Authorization"] = "Bearer " .. access_token,
    ["Accept"] = "application/json"
  })

  if not status or status < 200 or status >= 300 then
    return nil, "userinfo endpoint returned " .. tostring(status)
  end

  local cjson = require "cjson"
  local ok, userinfo = pcall(cjson.decode, body or "")
  if not ok or type(userinfo) ~= "table" then
    return nil, "userinfo endpoint did not return JSON"
  end

  return userinfo
end

-- ---------------------------------------------------------------------------
-- Session payload
-- ---------------------------------------------------------------------------

-- Build the session payload for an authenticated oauth2 principal.
-- Roles come from userinfo.roles (array) when present.
function _M.session_payload(userinfo, provider)
  local roles = {}
  if type(userinfo.roles) == "table" then
    for _, role in ipairs(userinfo.roles) do
      if type(role) == "string" then
        roles[#roles + 1] = role
      end
    end
  end

  return {
    subject = userinfo.sub or userinfo.email or userinfo.id or "oauth2-user",
    email = userinfo.email,
    roles = roles,
    method = "oauth2",
    provider = provider
  }
end

return _M
