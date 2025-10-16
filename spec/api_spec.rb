require_relative 'spec_helper'

RSpec.describe 'API Introspection Endpoints' do
  let(:client) { ApiClient.new }

  describe 'GET /api/v1/introspect/metadata' do
    it 'returns metadata for all packages' do
      response = client.get('/api/v1/introspect/metadata')
      expect(response.code).to eq('200')

      data = parse_json(response)
      expect(data).to have_key('packages')
      expect(data['packages']).to be_an(Array)

      # If there are packages, verify they have the expected structure
      unless data['packages'].empty?
        package = data['packages'][0]
        expect(package).to have_key('name')
        expect(package).to have_key('version')
      end
    end
  end

  describe 'GET /api/v1/introspect/routes' do
    it 'returns route information for all packages' do
      response = client.get('/api/v1/introspect/routes')
      expect(response.code).to eq('200')

      data = parse_json(response)
      expect(data).to have_key('routes')
      expect(data['routes']).to be_an(Array)

      # If there are routes, verify they have the expected structure
      unless data['routes'].empty?
        route_entry = data['routes'][0]
        expect(route_entry).to have_key('package')
        expect(route_entry).to have_key('routes')
        expect(route_entry['routes']).to be_an(Array)
      end
    end
  end

  describe 'GET /api/v1/introspect/content-hashes' do
    it 'returns content hashes for all packages' do
      response = client.get('/api/v1/introspect/content-hashes')
      expect(response.code).to eq('200')

      data = parse_json(response)
      expect(data).to have_key('contentHashes')
      expect(data['contentHashes']).to be_an(Array)

      # If there are content hashes, verify they have the expected structure
      unless data['contentHashes'].empty?
        hash_entry = data['contentHashes'][0]
        expect(hash_entry).to have_key('package')
        expect(hash_entry).to have_key('hash')
      end
    end
  end

  describe 'GET /api/v1/introspect/content-validity' do
    it 'returns content validity status for all packages' do
      response = client.get('/api/v1/introspect/content-validity')
      expect(response.code).to eq('200')

      data = parse_json(response)
      expect(data).to have_key('contentValidity')
      expect(data['contentValidity']).to be_an(Array)

      # If there are validity entries, verify they have the expected structure
      unless data['contentValidity'].empty?
        validity_entry = data['contentValidity'][0]
        expect(validity_entry).to have_key('package')
        expect(validity_entry).to have_key('valid')
        expect([true, false]).to include(validity_entry['valid'])
      end
    end
  end

  describe 'GET /api/v1/introspect/nonexistent' do
    it 'returns 404 for invalid API endpoints' do
      response = client.get('/api/v1/introspect/nonexistent')
      expect(response.code).to eq('404')

      data = parse_json(response)
      expect(data).to have_key('error')
    end
  end
end
