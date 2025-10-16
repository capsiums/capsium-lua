require_relative 'spec_helper'

RSpec.describe 'Configuration' do
  describe 'metadata API' do
    it 'returns configuration-aware data' do
      response = api_client.get('/api/v1/introspect/metadata')

      expect(response.code).to eq('200')

      data = parse_json(response)
      expect(data).to have_key('packages')
      expect(data['packages']).to be_an(Array)

      if data['packages'].any?
        package = data['packages'].first
        expect(package).to have_key('name')
        expect(package).to have_key('version')
      end
    end
  end

  describe 'routes API' do
    it 'returns configuration-aware routes' do
      response = api_client.get('/api/v1/introspect/routes')

      expect(response.code).to eq('200')

      data = parse_json(response)
      expect(data).to have_key('routes')
      expect(data['routes']).to be_an(Array)

      if data['routes'].any?
        route_entry = data['routes'].first
        expect(route_entry).to have_key('package')
        expect(route_entry).to have_key('routes')
        expect(route_entry['routes']).to be_an(Array)
      end
    end
  end

  describe 'custom mount path' do
    it 'allows accessing package at custom mount path' do
      response = api_client.get('/app/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to include('ISO sample documents in Metanorma')
    end

    it 'allows accessing resources with custom path' do
      response = api_client.get('/app/documents.xml')

      expect(response.code).to eq('200')
      expect(response['Content-Type'].downcase).to include('xml')
    end
  end

  describe 'custom headers' do
    it 'applies custom headers from configuration' do
      response = api_client.get('/app/')

      expect(response.code).to eq('200')
      expect(response['X-Frame-Options']).to eq('SAMEORIGIN')
      expect(response['X-Content-Type-Options']).to eq('nosniff')
    end
  end

  describe 'nested routes with custom path' do
    it 'serves nested routes correctly' do
      response = api_client.get('/app/index.html')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to include('ISO sample documents in Metanorma')
    end
  end

  describe 'default path' do
    it 'still works alongside custom paths' do
      response = api_client.get('/capsium/mn-samples-iso-0.1.0/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to include('ISO sample documents in Metanorma')
    end
  end

  describe 'nonexistent custom path' do
    it 'returns 404' do
      response = api_client.get('/nonexistent-path/')

      expect(response.code).to eq('404')
    end
  end

  describe 'domain-based routing' do
    it 'works with configured domains' do
      response = api_client.get_with_host('/app/', 'example.com')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to include('ISO sample documents in Metanorma')
      expect(response['X-Frame-Options']).to eq('SAMEORIGIN')
    end
  end

  describe 'domain and path combination' do
    it 'works with correct domain and path' do
      response = api_client.get_with_host('/app/documents.xml', 'example.com')

      expect(response.code).to eq('200')
      expect(response['Content-Type'].downcase).to include('xml')
    end

    it 'returns 404 for incorrect path' do
      response = api_client.get_with_host('/wrong-path/', 'example.com')

      expect(response.code).to eq('404')
    end
  end

  describe 'multiple domains' do
    it 'serves same content across domains' do
      response1 = api_client.get_with_host('/app/', 'example.com')
      response2 = api_client.get('/app/')

      expect(response1.code).to eq('200')
      expect(response2.code).to eq('200')
      expect(response1['X-Frame-Options']).to eq('SAMEORIGIN')

      expect(response1.body).to include('ISO sample documents in Metanorma')
      expect(response2.body).to include('ISO sample documents in Metanorma')
    end
  end
end
