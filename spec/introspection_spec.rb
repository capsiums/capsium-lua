require_relative 'spec_helper'

# Reactor-level and per-package introspection (07-reactor follow-ons,
# Ruby gem 0.4.0 parity): GET-only JSON endpoints
#   /introspect/status|config|metrics
#   /package/<name>/status|metadata|logs
RSpec.describe 'Reactor and per-package introspection' do
  let(:client) { ApiClient.new }

  describe 'GET /introspect/status' do
    it 'reports the reactor status' do
      response = client.get('/introspect/status')

      expect(response.code).to eq('200')
      expect(response.content_type).to include('application/json')

      data = parse_json(response)
      expect(data['status']).to eq('running')
      expect(data['uptime']).to be_a(Numeric)
      expect(data['uptime']).to be >= 0
      # 12 file mounts + 2 capsium:// registry mounts from config.json
      expect(data['packagesLoaded']).to eq(14)
    end
  end

  describe 'GET /introspect/config' do
    let(:data) { parse_json(client.get('/introspect/config')) }

    it 'reports mounts, registry, store and cache' do
      expect(data['mounts']).to be_an(Array)
      expect(data['mounts'].size).to eq(14)

      app = data['mounts'].find { |m| m['path'] == '/app' }
      expect(app['package']).to eq('mn-samples-iso-0.1.0.cap')
      expect(app['domain']).to eq('example.com')

      registry_mount = data['mounts'].find { |m| m['path'] == '/registry-app' }
      expect(registry_mount['package']).to eq('capsium://fixtures/registry-app')
      expect(registry_mount['version']).to eq('>=1.0.0')

      expect(data['registry']).to eq('/var/lib/capsium/registry')
      expect(data['storeDir']).to eq('/var/lib/capsium/store')
      expect(data['cache']).to eq('enabled' => true, 'ttl' => 3600)
      expect(data['authEnabled']).to eq(true)
    end

    it 'never exposes secrets or key material' do
      body = client.get('/introspect/config').body

      expect(body).not_to include('integration-test-session-secret')
      expect(body).not_to include('mock-client-secret')
      expect(body).not_to include('private.pem')
      expect(body).not_to include('sessionSecret')
      expect(body).not_to include('clientSecret')
      expect(body).not_to include('privateKeyPath')
    end
  end

  describe 'GET /introspect/metrics' do
    it 'counts requests across requests' do
      first = parse_json(client.get('/introspect/metrics'))
      expect(first['requestsTotal']).to be_a(Numeric)
      expect(first['requestsByStatus']).to be_a(Hash)

      client.get('/')                  # 200 (static welcome page)
      client.get('/no-such-mount/xyz') # 404
      client.get('/introspect/status') # 200

      second = parse_json(client.get('/introspect/metrics'))

      # +4: the first metrics read itself plus the three requests above
      expect(second['requestsTotal'] - first['requestsTotal']).to eq(4)
      status_200 = second['requestsByStatus']['200'].to_i -
                   first['requestsByStatus']['200'].to_i
      status_404 = second['requestsByStatus']['404'].to_i -
                   first['requestsByStatus']['404'].to_i
      expect(status_200).to eq(3)
      expect(status_404).to eq(1)
      expect(second['uptime']).to be >= first['uptime']
    end
  end

  describe 'GET /package/<name>/status' do
    it 'reports a mounted package' do
      response = client.get('/package/mn-samples-iso/status')

      expect(response.code).to eq('200')
      data = parse_json(response)
      expect(data['package']).to eq('mn-samples-iso')
      expect(data['version']).to eq('0.1.0')
      expect(data['status']).to eq('loaded')
      expect(data['valid']).to eq(true)
    end

    it '404s for an unknown package name' do
      response = client.get('/package/does-not-exist/status')

      expect(response.code).to eq('404')
      expect(parse_json(response)).to have_key('error')
    end
  end

  describe 'GET /package/<name>/metadata' do
    it 'reports package metadata (registry-resolved package)' do
      response = client.get('/package/registry-app/metadata')

      expect(response.code).to eq('200')
      data = parse_json(response)
      expect(data['name']).to eq('registry-app')
      expect(data['version']).to eq('1.1.0')
      expect(data['description']).to include('Registry-served')
      expect(data['author']).to eq('Ribose')
      expect(data['guid']).to eq('capsium://fixtures/registry-app')
    end

    it '404s for an unknown package name' do
      expect(client.get('/package/does-not-exist/metadata').code).to eq('404')
    end
  end

  describe 'GET /package/<name>/logs' do
    it 'returns recent ring-buffer lines' do
      # The ring buffer is per worker: fan requests out so the worker
      # answering the logs request has entries (retry a few times).
      lines = nil
      10.times do
        client.get('/package/mn-samples-iso/status')
        response = client.get('/package/mn-samples-iso/logs')
        expect(response.code).to eq('200')
        data = parse_json(response)
        expect(data['package']).to eq('mn-samples-iso')
        expect(data['logs']).to be_an(Array)
        lines = data['logs']
        break unless lines.empty?
      end

      expect(lines).not_to be_empty
      expect(lines).to all(match(%r{^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z (GET|HEAD) .+ -> \d{3}$}))
    end

    it 'honors the ?lines= limit' do
      5.times { client.get('/package/mn-samples-iso/status') }

      response = client.get('/package/mn-samples-iso/logs?lines=1')
      expect(response.code).to eq('200')
      expect(parse_json(response)['logs'].size).to be <= 1
    end

    it '404s for an unknown package name' do
      expect(client.get('/package/does-not-exist/logs').code).to eq('404')
    end
  end

  describe 'CORS (rules of the mount serving the package)' do
    it 'applies the mount CORS policy to per-package endpoints' do
      response = client.get('/package/multi-test/metadata',
                            'Origin' => 'https://example.com')

      expect(response.code).to eq('200')
      expect(response['Access-Control-Allow-Origin'])
        .to eq('https://example.com')
    end

    it 'does not emit CORS headers for disallowed origins' do
      response = client.get('/package/multi-test/metadata',
                            'Origin' => 'https://evil.example.com')

      expect(response['Access-Control-Allow-Origin']).to be_nil
    end
  end

  describe 'method restrictions (GET-only)' do
    it 'rejects POST on reactor endpoints with 405 + Allow' do
      response = client.post('/introspect/status')

      expect(response.code).to eq('405')
      expect(response['Allow']).to eq('GET')
    end

    it 'rejects POST on per-package endpoints with 405 + Allow' do
      response = client.post('/package/mn-samples-iso/logs')

      expect(response.code).to eq('405')
      expect(response['Allow']).to eq('GET')
    end
  end
end
