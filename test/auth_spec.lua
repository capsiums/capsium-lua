describe("capsium.auth (ARCHITECTURE.md section 4b)", function()
  local htpasswd = require "capsium.auth.htpasswd"
  local basic = require "capsium.auth.basic"
  local session = require "capsium.auth.session"
  local oauth2 = require "capsium.auth.oauth2"
  local access = require "capsium.auth.access"
  local utils = require "capsium.utils"
  local crypto = require "capsium.crypto"

  -- Precomputed with the platform htpasswd tool (password: s3cret-Passw0rd!)
  local HTPASSWD = table.concat({
    "admin:$apr1$IkldN8OR$D18fzzuWsa5ggBAj53emV1",
    "sunny:{SHA}XjI/xlvqp2zHwHdmWdxg1QS5lbM=",
    "betty:$2y$05$XlUpJYPb8qhxQMbXN3.O0OMRwFk7CMeS8/Wjx5J31R1F71eNjhADO",
    "diesel:/YeWhmCiNKpIU",
    "# a comment",
    ""
  }, "\n")

  -- htpasswd/basic/session need the crypto backend (digests, hmac, crypt)
  local function describe_backend(name, fn)
    if crypto.available() then
      describe(name, fn)
    else
      pending(name .. " skipped: crypto backend unavailable",
              function() end)
    end
  end

  describe_backend("htpasswd", function()
    it("verifies apr1 (Apache MD5) entries", function()
      assert.is_true(htpasswd.verify(HTPASSWD, "admin", "s3cret-Passw0rd!"))
      assert.is_false(htpasswd.verify(HTPASSWD, "admin", "wrong"))
    end)

    it("verifies {SHA} (SHA-1 base64) entries", function()
      assert.is_true(htpasswd.verify(HTPASSWD, "sunny", "s3cret-Passw0rd!"))
      assert.is_false(htpasswd.verify(HTPASSWD, "sunny", "wrong"))
    end)

    it("verifies bcrypt entries via crypt(3)", function()
      assert.is_true(htpasswd.verify(HTPASSWD, "betty", "s3cret-Passw0rd!"))
      assert.is_false(htpasswd.verify(HTPASSWD, "betty", "wrong"))
    end)

    it("verifies traditional DES crypt entries", function()
      -- htpasswd truncates DES passwords to 8 characters
      assert.is_true(htpasswd.verify(HTPASSWD, "diesel", "secret123"))
      assert.is_false(htpasswd.verify(HTPASSWD, "diesel", "wrong"))
    end)

    it("rejects unknown users and malformed input", function()
      assert.is_false(htpasswd.verify(HTPASSWD, "nobody", "x"))
      assert.is_false(htpasswd.verify(nil, "admin", "x"))
      assert.is_false(htpasswd.verify("garbage", "admin", "x"))
      assert.is_false(htpasswd.verify(HTPASSWD, "admin", nil))
    end)

    it("computes apr1 hashes matching the platform tool", function()
      -- Cross-check: the precomputed vector round-trips through verify_hash
      assert.is_true(htpasswd.verify_hash("s3cret-Passw0rd!",
        "$apr1$IkldN8OR$D18fzzuWsa5ggBAj53emV1"))
    end)
  end)

  describe_backend("basic", function()
    local function header_for(user, pass)
      return "Basic " .. utils.base64_encode(user .. ":" .. pass)
    end

    it("authenticates valid credentials", function()
      local principal = assert(basic.authenticate(
        header_for("admin", "s3cret-Passw0rd!"), HTPASSWD))

      assert.equals("admin", principal.subject)
      assert.equals("basic", principal.method)
      assert.same({}, principal.roles)
    end)

    it("assigns deploy-time roles to the principal", function()
      local deploy_roles = { admin = { "admin", "editor" }, other = { "x" } }

      local principal = assert(basic.authenticate(
        header_for("admin", "s3cret-Passw0rd!"), HTPASSWD, deploy_roles))
      assert.same({ "admin", "editor" }, principal.roles)

      -- Users without a deploy assignment keep empty roles
      local sunny = assert(basic.authenticate(
        header_for("sunny", "s3cret-Passw0rd!"), HTPASSWD, deploy_roles))
      assert.same({}, sunny.roles)

      -- Non-string entries are ignored
      local mixed = assert(basic.authenticate(
        header_for("admin", "s3cret-Passw0rd!"), HTPASSWD,
        { admin = { "admin", 5, true } }))
      assert.same({ "admin" }, mixed.roles)
    end)

    it("rejects invalid credentials and malformed headers", function()
      assert.is_nil(basic.authenticate(header_for("admin", "wrong"),
                                       HTPASSWD))
      assert.is_nil(basic.authenticate("Bearer abc", HTPASSWD))
      assert.is_nil(basic.authenticate("Basic !!!", HTPASSWD))
      assert.is_nil(basic.authenticate("Basic " ..
        utils.base64_encode("no-colon"), HTPASSWD))
      assert.is_nil(basic.authenticate(nil, HTPASSWD))
    end)
  end)

  describe_backend("session", function()
    local secret = "test-deploy-secret"

    it("round-trips a signed payload", function()
      local value = session.sign({ subject = "alice", roles = { "r" } },
                                 secret, 3600, 1000)
      local payload = assert(session.verify(value, secret, 1000))

      assert.equals("alice", payload.subject)
      assert.same({ "r" }, payload.roles)
      assert.equals(4600, payload.exp)
    end)

    it("rejects tampering and wrong secrets", function()
      local value = session.sign({ subject = "alice" }, secret, 3600, 1000)

      assert.is_nil(session.verify(value, "other-secret", 1000))
      assert.is_nil(session.verify(value:sub(1, -3) ..
        (value:sub(-1) == "a" and "b" or "a"), secret, 1000))
      assert.is_nil(session.verify("not.a.session", secret, 1000))
      assert.is_nil(session.verify(nil, secret, 1000))
    end)

    it("enforces expiry", function()
      local value = session.sign({ subject = "alice" }, secret, 60, 1000)

      assert.is_not_nil(session.verify(value, secret, 1059))
      assert.is_nil(session.verify(value, secret, 1060))
    end)

    it("base64url round-trips without padding", function()
      local encoded = session.base64url_encode("binary\x00\x01\x02?+/#")
      assert.is_falsy(encoded:find("[=+/]"))
      assert.equals("binary\x00\x01\x02?+/#",
                    session.base64url_decode(encoded))
    end)
  end)

  describe("oauth2", function()
    local config = {
      client_id = "capsium-test",
      authorization_url = "https://provider.example/authorize",
      token_url = "https://provider.example/token",
      userinfo_url = "https://provider.example/userinfo",
      redirect_path = "/auth/callback",
      scopes = { "openid", "profile" }
    }

    it("builds the authorization URL with PKCE", function()
      local url = oauth2.authorization_url(config,
        "http://localhost:8080/app/auth/callback", "state123", "challenge456")

      assert.is_truthy(url:find("^https://provider%.example/authorize?"))
      assert.is_truthy(url:find("response_type=code"))
      assert.is_truthy(url:find("client_id=capsium%-test"))
      assert.is_truthy(url:find("redirect_uri=" ..
        utils.url_encode("http://localhost:8080/app/auth/callback"):gsub("%%", "%%%%")))
      assert.is_truthy(url:find("state=state123"))
      assert.is_truthy(url:find("code_challenge=challenge456"))
      assert.is_truthy(url:find("code_challenge_method=S256"))
      assert.is_truthy(url:find("scope=openid%%20profile") or
                       url:find("scope=openid%+" ..
                                "profile"))
    end)

    it("creates PKCE pairs whose challenge is the S256 of the verifier",
       function()
      if not crypto.available() then
        pending("crypto backend unavailable")
        return
      end

      local pkce = oauth2.new_pkce()
      assert.equals(43, #pkce.verifier)

      require "resty.openssl.version"
      local digest = require "resty.openssl.digest"
      local ctx = digest.new("sha256")
      ctx:update(pkce.verifier)
      assert.equals(session.base64url_encode(ctx:final()),
                    pkce.challenge)
    end)

    it("exchanges codes via the injected HTTP client", function()
      local posted
      local tokens = assert(oauth2.exchange_code(config, "code123",
        "verifier123", "http://localhost/cb",
        function(url, headers, body)
          posted = { url = url, headers = headers, body = body }
          return 200, '{"access_token":"tok-abc","token_type":"Bearer"}'
        end))

      assert.equals("https://provider.example/token", posted.url)
      assert.is_truthy(posted.body:find("grant_type=authorization_code"))
      assert.is_truthy(posted.body:find("code=code123"))
      assert.is_truthy(posted.body:find("code_verifier=verifier123"))
      assert.equals("tok-abc", tokens.access_token)
    end)

    it("fails cleanly on token endpoint errors", function()
      local tokens, err = oauth2.exchange_code(config, "bad", "v",
        "http://localhost/cb", function()
          return 400, '{"error":"invalid_grant"}'
        end)

      assert.is_nil(tokens)
      assert.is_truthy(tostring(err):find("400"))

      local tokens2 = oauth2.exchange_code(config, "x", "v",
        "http://localhost/cb", function()
          return 200, "not json"
        end)
      assert.is_nil(tokens2)
    end)

    it("fetches userinfo with the access token", function()
      local got
      local userinfo = assert(oauth2.fetch_userinfo(config, "tok-abc",
        function(url, headers)
          got = { url = url, headers = headers }
          return 200, '{"sub":"user-1","roles":["reader"]}'
        end))

      assert.equals("Bearer tok-abc", got.headers["Authorization"])
      assert.equals("user-1", userinfo.sub)
    end)

    it("builds session payloads with roles", function()
      local payload = oauth2.session_payload({
        sub = "user-1", email = "u@example.com", roles = { "reader", 5 }
      }, "mock")

      assert.equals("user-1", payload.subject)
      assert.equals("u@example.com", payload.email)
      assert.same({ "reader" }, payload.roles)
      assert.equals("oauth2", payload.method)
      assert.equals("mock", payload.provider)
    end)
  end)

  describe("access.evaluate", function()
    it("allows when no accessControl is set", function()
      assert.equals("allow", access.evaluate(nil, nil))
      assert.equals("allow", access.evaluate({}, nil))
    end)

    it("maps authenticationRequired to 401 when unauthenticated", function()
      assert.equals("unauthenticated", access.evaluate({
        authenticationRequired = true
      }, nil))
      assert.equals("allow", access.evaluate({
        authenticationRequired = true
      }, { subject = "a", roles = {} }))
    end)

    it("maps roles to 403 unless held", function()
      assert.equals("forbidden", access.evaluate({
        roles = { "admin" }
      }, { subject = "a", roles = {} }))
      assert.equals("forbidden", access.evaluate({
        roles = { "admin" }
      }, nil))
      assert.equals("allow", access.evaluate({
        roles = { "admin", "reader" }
      }, { subject = "a", roles = { "reader" } }))
    end)
  end)
end)
