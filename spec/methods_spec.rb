require_relative 'spec_helper'

RSpec.describe 'HTTP method enforcement' do
  describe 'package routes are GET-only' do
    it 'rejects POST with 405 and an Allow header', :aggregate_failures do
      response = api_client.post('/app/')

      expect(response.code).to eq('405')
      expect(response['Allow']).to include('GET')
    end

    it 'rejects POST on auto-mounted packages' do
      response = api_client.post('/capsium/mn-samples-iso-0.1.0/')

      expect(response.code).to eq('405')
    end
  end

  describe 'introspection endpoints are GET-only' do
    it 'rejects POST with 405', :aggregate_failures do
      response = api_client.post('/api/v1/introspect/metadata')

      expect(response.code).to eq('405')
      expect(response['Allow']).to include('GET')
    end
  end

  describe 'HEAD requests' do
    it 'are served like GET without a body', :aggregate_failures do
      response = api_client.request(:head, '/app/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to be_nil
    end
  end
end
