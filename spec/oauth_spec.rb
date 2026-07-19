require_relative 'spec_helper'
require 'webrick'
require 'base64'
require 'digest'
require 'socket'

# Full OAuth2 authorization-code + PKCE round trip against a mock provider
# served by WEBrick (ARCHITECTURE.md §4b). The reactor redirects the
# unauthenticated client to the provider, the provider redirects back with
# a code, the reactor exchanges it (server-side, PKCE-verified) and
# establishes a signed session cookie.
RSpec.describe 'OAuth2 authentication (ARCHITECTURE.md §4b)' do
  PROVIDER_PORT = 9292
  ACCESS_TOKEN = 'mock-access-token'

  before(:all) do
    @challenge = nil
    logger = WEBrick::Log.new(File::NULL)
    @provider = WEBrick::HTTPServer.new(
      BindAddress: '0.0.0.0', Port: PROVIDER_PORT, Logger: logger,
      AccessLog: []
    )

    @provider.mount_proc('/oauth/authorize') do |req, res|
      @challenge = req.query['code_challenge']
      redirect_uri = req.query['redirect_uri']
      state = req.query['state']
      res.status = 302
      res['Location'] = "#{redirect_uri}?code=mock-code-123&state=#{state}"
    end

    @provider.mount_proc('/oauth/token') do |req, res|
      params = WEBrick::HTTPUtils.parse_query(req.body)
      verifier = params['code_verifier'].to_s
      computed = Base64.urlsafe_encode64(
        Digest::SHA256.digest(verifier), padding: false)

      if params['grant_type'] == 'authorization_code' &&
         params['code'] == 'mock-code-123' &&
         !@challenge.nil? && computed == @challenge
        res.status = 200
        res['Content-Type'] = 'application/json'
        res.body = JSON.generate(
          access_token: ACCESS_TOKEN, token_type: 'Bearer')
      else
        res.status = 400
        res['Content-Type'] = 'application/json'
        res.body = JSON.generate(error: 'invalid_grant')
      end
    end

    @provider.mount_proc('/oauth/userinfo') do |req, res|
      if req['Authorization'] == "Bearer #{ACCESS_TOKEN}"
        res.status = 200
        res['Content-Type'] = 'application/json'
        res.body = JSON.generate(
          sub: 'oauth-user-1', email: 'user@example.com', roles: ['reader'])
      else
        res.status = 401
      end
    end

    @thread = Thread.new { @provider.start }
    # Wait until the provider accepts connections
    30.times do
      begin
        TCPSocket.new('127.0.0.1', PROVIDER_PORT).close
        break
      rescue Errno::ECONNREFUSED
        sleep 0.1
      end
    end
  end

  after(:all) do
    @provider.shutdown
    @thread.join(5)
  end

  # Cookie-keeping little client for the browser-less dance
  def get_cookie_jar
    @cookies ||= {}
  end

  def store_cookies(response)
    Array(response.get_fields('Set-Cookie')).each do |cookie|
      pair = cookie.split(';').first
      name, value = pair.split('=', 2)
      get_cookie_jar[name] = value
    end
  end

  def cookie_header
    get_cookie_jar.map { |k, v| "#{k}=#{v}" }.join('; ')
  end

  def get(url, headers = {})
    uri = URI(url)
    headers = headers.merge('Cookie' => cookie_header) unless cookie_header.empty?
    Net::HTTP.start(uri.hostname, uri.port) do |http|
      response = http.get(uri.request_uri, headers)
      store_cookies(response)
      response
    end
  end

  before(:each) do
    @cookies = {}
  end

  def complete_oauth_dance!
    # 1. Unauthenticated request redirects to the provider
    response = get('http://localhost:8080/oauth-app/')
    expect(response.code).to eq('302')

    location = response['Location']
    expect(location).to include('/oauth/authorize')
    expect(location).to include('client_id=capsium-test')
    expect(location).to include('code_challenge=')
    expect(location).to include('code_challenge_method=S256')
    expect(get_cookie_jar['capsium_oauth_state']).not_to be_nil

    # 2. The provider redirects back with a code (host-side the provider
    #    is reached at localhost; the reactor reaches it via
    #    host.docker.internal)
    provider_url = location.sub('host.docker.internal', 'localhost')
    response = get(provider_url)
    expect(response.code).to eq('302')

    # 3. The callback exchanges the code and establishes the session
    callback = URI(response['Location'])
    response = get("http://#{callback.host}:#{callback.port}#{callback.request_uri}")
    expect(response.code).to eq('302')
    expect(get_cookie_jar['capsium_session']).not_to be_nil
    response
  end

  it 'redirects unauthenticated requests to the provider', :aggregate_failures do
    response = get('http://localhost:8080/oauth-app/')

    expect(response.code).to eq('302')
    expect(response['Location']).to include('response_type=code')
    expect(response['Location']).to include('redirect_uri=')
    expect(response['Location']).to include('state=')
    expect(response['Location']).to include('scope=openid')
  end

  it 'completes the PKCE flow and serves content with the session',
     :aggregate_failures do
    complete_oauth_dance!

    response = get('http://localhost:8080/oauth-app/')
    expect(response.code).to eq('200')
    expect(response.body).to include('OAuth2 protected area')
  end

  it 'allows role-matching dataset access (roles from userinfo)' do
    complete_oauth_dance!

    response = get('http://localhost:8080/oauth-app/api/v1/data/reader-data')
    expect(response.code).to eq('200')
    expect(parse_json(response).first['name']).to eq('reader-raita')
  end

  it 'answers 403 for dataset routes whose roles are not held' do
    complete_oauth_dance!

    response = get('http://localhost:8080/oauth-app/api/v1/data/admin-data')
    expect(response.code).to eq('403')
  end

  it 'restarts the flow for a tampered session cookie' do
    complete_oauth_dance!

    get_cookie_jar['capsium_session'] =
      "#{get_cookie_jar['capsium_session'][0..-3]}tampered"
    response = get('http://localhost:8080/oauth-app/')
    expect(response.code).to eq('302')
    expect(response['Location']).to include('/oauth/authorize')
  end

  it 'rejects a callback with mismatched state' do
    response = get('http://localhost:8080/oauth-app/')
    expect(response.code).to eq('302')

    response = get('http://localhost:8080/oauth-app/auth/callback' \
                   '?code=mock-code-123&state=forged-state')
    expect(response.code).to eq('400')
    expect(parse_json(response)['error']).to match(/state/i)
  end
end
