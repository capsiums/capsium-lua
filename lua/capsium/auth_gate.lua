-- capsium-lua Nginx glue: authentication gate (ARCHITECTURE.md section 4b)
--
-- Wires the framework-agnostic capsium.auth.* modules into ngx: Basic
-- challenges, OAuth2 authorization-code + PKCE redirects and the token
-- exchange (via resty.http, lazy — it only loads inside nginx workers),
-- and signed-cookie session handling.
--
-- All domain logic (htpasswd, basic scheme, session signing, oauth2 flow
-- math, access evaluation) lives in lib/capsium/auth/*.lua; this module
-- only translates to/from ngx.

local basic_auth = require "capsium.auth.basic"
local oauth2 = require "capsium.auth.oauth2"
local session = require "capsium.auth.session"
local access = require "capsium.auth.access"
local fs = require("capsium.adapters.nginx").fs_adapter

local cjson = require "cjson"

local _M = {
  _VERSION = "0.4.0"
}

local SESSION_COOKIE = "capsium_session"
local STATE_COOKIE = "capsium_oauth_state"
local STATE_TTL = 300 -- seconds; authorization round-trip budget

-- ---------------------------------------------------------------------------
-- Response helpers
-- ---------------------------------------------------------------------------

local function respond_json(status, data)
  ngx.status = status
  ngx.header.content_type = "application/json"
  ngx.say(cjson.encode(data))
  return ngx.exit(status)
end

local function cookie_string(name, value, path, max_age)
  local parts = {
    name .. "=" .. value,
    "Path=" .. path,
    "HttpOnly",
    "SameSite=Lax"
  }
  if max_age then
    parts[#parts + 1] = "Max-Age=" .. max_age
  end
  if ngx.var.https == "on" then
    parts[#parts + 1] = "Secure"
  end
  return table.concat(parts, "; ")
end

local function redirect(location, cookies)
  ngx.status = ngx.HTTP_MOVED_TEMPORARILY
  ngx.header["Location"] = location
  if cookies then
    ngx.header["Set-Cookie"] = cookies
  end
  return ngx.exit(ngx.HTTP_MOVED_TEMPORARILY)
end

local function challenge(realm)
  ngx.header["WWW-Authenticate"] = 'Basic realm="' .. (realm or "capsium") ..
                                   '"'
  return respond_json(ngx.HTTP_UNAUTHORIZED,
                      { error = "Authentication required" })
end

-- ---------------------------------------------------------------------------
-- Request helpers
-- ---------------------------------------------------------------------------

local function request_cookie(name)
  local header = ngx.var.http_cookie
  if not header then
    return nil
  end
  for pair in header:gmatch("[^;]+") do
    local key, value = pair:match("^%s*([^=]+)=(.*)$")
    if key == name then
      return value
    end
  end
  return nil
end

-- Absolute callback URI for this request + mount + redirect path
local function redirect_uri(mount, redirect_path)
  local scheme = ngx.var.https == "on" and "https" or "http"
  -- The raw Host header keeps the client-facing port ($host strips it)
  local authority = ngx.var.http_host
  if not authority or authority == "" then
    authority = ngx.var.host
    local port = tonumber(ngx.var.server_port)
    local default_port = (scheme == "https" and 443 or 80)
    if port and port ~= default_port then
      authority = authority .. ":" .. port
    end
  end

  local base = mount.path == "/" and "" or mount.path
  return scheme .. "://" .. authority .. base .. redirect_path
end

-- ---------------------------------------------------------------------------
-- HTTP client (resty.http; only loads inside nginx workers)
-- ---------------------------------------------------------------------------

local function http_client()
  local ok, http = pcall(require, "resty.http")
  if not ok then
    return nil
  end
  return http
end

local function http_post(url, headers, body)
  local http = http_client()
  if not http then
    return nil, "resty.http unavailable"
  end

  local client = http.new()
  client:set_timeout(5000)
  local res, err = client:request_uri(url, {
    method = "POST",
    headers = headers,
    body = body
  })
  if not res then
    return nil, err
  end
  return res.status, res.body
end

local function http_get(url, headers)
  local http = http_client()
  if not http then
    return nil, "resty.http unavailable"
  end

  local client = http.new()
  client:set_timeout(5000)
  local res, err = client:request_uri(url, {
    method = "GET",
    headers = headers
  })
  if not res then
    return nil, err
  end
  return res.status, res.body
end

-- ---------------------------------------------------------------------------
-- OAuth2
-- ---------------------------------------------------------------------------

-- Begin the authorization-code + PKCE flow: state + verifier in a signed
-- short-lived cookie, browser redirected to the provider.
local function begin_oauth2(oauth_config, mount, deploy, return_to)
  if not deploy.session_secret then
    return respond_json(ngx.HTTP_INTERNAL_SERVER_ERROR, {
      error = "OAuth2 is enabled but no session secret is configured " ..
              "(authentication.sessionSecret / CAPSIUM_SESSION_SECRET)"
    })
  end

  local pkce = oauth2.new_pkce()
  local state = oauth2.random_token()
  local callback = redirect_uri(mount, oauth_config.redirect_path)

  local state_value = session.sign({
    state = state,
    verifier = pkce.verifier,
    return_to = return_to
  }, deploy.session_secret, STATE_TTL)

  local location = oauth2.authorization_url(oauth_config, callback,
                                            state, pkce.challenge)
  return redirect(location, {
    cookie_string(STATE_COOKIE, state_value, "/", STATE_TTL)
  })
end

-- Handle the provider callback: verify state, exchange the code, fetch
-- userinfo, set the session cookie, redirect to the original path.
local function handle_oauth2_callback(oauth_config, mount, deploy)
  if not deploy.session_secret then
    return respond_json(ngx.HTTP_INTERNAL_SERVER_ERROR, {
      error = "OAuth2 is enabled but no session secret is configured " ..
              "(authentication.sessionSecret / CAPSIUM_SESSION_SECRET)"
    })
  end

  local args = ngx.req.get_uri_args()
  local code, state = args.code, args.state
  if type(code) ~= "string" or type(state) ~= "string" then
    return respond_json(ngx.HTTP_BAD_REQUEST,
                        { error = "OAuth2 callback missing code or state" })
  end

  local pending = session.verify(request_cookie(STATE_COOKIE),
                                 deploy.session_secret)
  if not pending or pending.state ~= state then
    return respond_json(ngx.HTTP_BAD_REQUEST,
                        { error = "OAuth2 state mismatch" })
  end

  local effective = {
    client_id = oauth_config.client_id,
    client_secret = deploy.oauth2_client_secret,
    authorization_url = oauth_config.authorization_url,
    token_url = oauth_config.token_url,
    userinfo_url = oauth_config.userinfo_url,
    redirect_path = oauth_config.redirect_path,
    scopes = oauth_config.scopes
  }

  local callback = redirect_uri(mount, oauth_config.redirect_path)
  local tokens, terr = oauth2.exchange_code(effective, code,
                                            pending.verifier, callback,
                                            http_post)
  if not tokens then
    return respond_json(ngx.HTTP_BAD_GATEWAY, {
      error = "OAuth2 token exchange failed: " .. tostring(terr)
    })
  end

  local userinfo, uerr = oauth2.fetch_userinfo(effective,
                                               tokens.access_token,
                                               http_get)
  if not userinfo then
    return respond_json(ngx.HTTP_BAD_GATEWAY, {
      error = "OAuth2 userinfo failed: " .. tostring(uerr)
    })
  end

  local principal = oauth2.session_payload(userinfo, oauth_config.provider)
  local session_value = session.sign(principal, deploy.session_secret,
                                     deploy.session_ttl)

  local return_to = pending.return_to
  if type(return_to) ~= "string" or return_to:sub(1, 1) ~= "/" then
    return_to = mount.path == "/" and "/" or mount.path
  end

  return redirect(return_to, {
    cookie_string(SESSION_COOKIE, session_value, "/", deploy.session_ttl),
    cookie_string(STATE_COOKIE, "deleted", "/", 0)
  })
end

-- ---------------------------------------------------------------------------
-- The gate
-- ---------------------------------------------------------------------------

-- Read an htpasswd file: package-relative paths resolve inside the
-- extracted package; absolute paths are used as-is (referenced file).
local function read_htpasswd(package, passwd_file)
  local path = passwd_file
  if path:sub(1, 1) ~= "/" then
    path = package.extract_path .. "/" .. path
  end
  return fs.read_file(path, "rb")
end

-- Establish the request principal for a package with authentication.
--   package:  the loaded Package (authentication.json already parsed)
--   mount:    the matched mount view
--   subpath:  request path within the mount
--   deploy:   normalized deploy authentication config (secrets, ttl)
--
-- Returns the principal table, or nil when the gate already answered the
-- request (401 challenge, OAuth2 redirect/callback, or an error).
function _M.gate(package, mount, subpath, deploy)
  local authn = package:get_authentication()
  if not authn then
    return {} -- no authentication configured: nothing to enforce
  end

  local oauth_config = authn.oauth2

  -- The OAuth2 callback path is answered by the flow itself
  if oauth_config and subpath == oauth_config.redirect_path then
    handle_oauth2_callback(oauth_config, mount, deploy)
    return nil
  end

  -- 1. Basic credentials win when basicAuth is enabled
  if authn.basicAuth then
    local header = ngx.var.http_authorization
    if header then
      local htpasswd_content = read_htpasswd(package,
                                             authn.basicAuth.passwd_file)
      if not htpasswd_content then
        respond_json(ngx.HTTP_INTERNAL_SERVER_ERROR, {
          error = "basicAuth passwdFile is unreadable: " ..
                  authn.basicAuth.passwd_file
        })
        return nil
      end

      local principal = basic_auth.authenticate(header, htpasswd_content)
      if principal then
        return principal
      end

      challenge(authn.basicAuth.realm)
      return nil
    end
  end

  -- 2. An established oauth2 session
  if oauth_config and deploy.session_secret then
    local payload = session.verify(request_cookie(SESSION_COOKIE),
                                   deploy.session_secret)
    if payload then
      return {
        subject = payload.subject,
        email = payload.email,
        roles = payload.roles or {},
        method = "oauth2",
        provider = payload.provider
      }
    end
  end

  -- 3. Nothing authenticated: redirect to the provider when possible,
  --    otherwise challenge for Basic credentials
  if oauth_config then
    begin_oauth2(oauth_config, mount, deploy, ngx.var.request_uri)
    return nil
  end

  challenge(authn.basicAuth and authn.basicAuth.realm or "capsium")
  return nil
end

-- Enforce a dataset route's accessControl against the principal.
-- Answers the request and returns false when access is denied.
function _M.enforce_dataset_access(target, principal, authn)
  local verdict = access.evaluate(target.accessControl,
                                  principal and principal.subject
                                  and principal or nil)

  if verdict == "allow" then
    return true
  end

  if verdict == "unauthenticated" then
    if authn and authn.basicAuth then
      challenge(authn.basicAuth.realm)
    else
      respond_json(ngx.HTTP_UNAUTHORIZED,
                   { error = "Authentication required" })
    end
    return false
  end

  respond_json(ngx.HTTP_FORBIDDEN,
               { error = "Forbidden: insufficient role" })
  return false
end

return _M
