require_relative 'spec_helper'

# Static registry pull: config.json declares a reactor-level registry
# (/var/lib/capsium/registry, a local-dir fixture) and two mounts whose
# package source is a capsium:// reference resolved against that
# registry's index.json (newest satisfying semver, sha256-verified,
# installed into the package store).
RSpec.describe 'Static registry pull (capsium:// mount sources)' do
  let(:client) { ApiClient.new }
  let(:store_file) do
    File.join(__dir__, 'fixtures', 'store', 'registry-app-1.1.0.cap')
  end

  describe 'GET /registry-app/ (capsium://fixtures/registry-app, >=1.0.0)' do
    it 'serves the newest satisfying version from the registry' do
      response = client.get('/registry-app/')

      expect(response.code).to eq('200')
      expect(response.body).to include('Registry app v1.1.0')
    end

    it 'installs the resolved package into the package store' do
      client.get('/registry-app/') # ensure the lazy resolution happened

      expect(File).to exist(store_file)
      expect(File.binread(store_file)).to eq(
        File.binread(File.join(__dir__, 'fixtures', 'registry',
                               'registry-app-1.1.0.cap'))
      )
    end
  end

  describe 'GET /registry-tampered/ (index sha256 does not match)' do
    it 'rejects the install with a typed 5xx and the reason' do
      response = client.get('/registry-tampered/')

      expect(response.code).to eq('500')
      data = parse_json(response)
      expect(data['error']).to include('sha256 mismatch')
      expect(data['error']).to include('registry-tampered-1.0.0.cap')
      expect(data['type']).to eq('checksum_mismatch')
    end

    it 'does not install the tampered package into the store' do
      client.get('/registry-tampered/')

      expect(File).not_to exist(
        File.join(__dir__, 'fixtures', 'store',
                  'registry-tampered-1.0.0.cap')
      )
    end
  end

  describe 'store reuse across restarts' do
    def restart_container
      system('docker restart capsium-nginx-test',
             out: File::NULL, err: File::NULL) or
        raise 'docker restart failed'

      # Wait until the reactor answers again
      30.times do |attempt|
        begin
          response = client.get('/api/v1/introspect/metadata')
          return if response.code == '200'
        rescue StandardError
          # server not up yet
        end
        sleep 1
        raise 'server did not come back after restart' if attempt == 29
      end
    end

    it 'serves the resolved package without reinstalling it' do
      response = client.get('/registry-app/')
      expect(response.code).to eq('200')
      expect(File).to exist(store_file)
      mtime_before = File.mtime(store_file)

      restart_container

      response = client.get('/registry-app/')
      expect(response.code).to eq('200')
      expect(response.body).to include('Registry app v1.1.0')
      # The store file was reused as-is (no download, no rewrite)
      expect(File.mtime(store_file)).to eq(mtime_before)
    end
  end
end
