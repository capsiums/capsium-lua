require_relative 'spec_helper'

RSpec.describe 'CORS (per-mount options.cors)' do
  let(:cors_headers) do
    {
      'Origin' => 'https://example.com',
      'Access-Control-Request-Method' => 'GET'
    }
  end

  describe 'mount with CORS configured' do
    it 'answers preflight OPTIONS requests', :aggregate_failures do
      response = api_client.options('/multi/', cors_headers)

      expect(response.code).to eq('204')
      expect(response['Access-Control-Allow-Origin']).to eq('https://example.com')
      expect(response['Access-Control-Allow-Methods']).to include('GET')
      expect(response['Access-Control-Allow-Headers']).to include('Content-Type')
      expect(response['Access-Control-Max-Age']).to eq('600')
    end

    it 'adds Allow-Origin to actual requests', :aggregate_failures do
      response = api_client.get('/multi/', { 'Origin' => 'https://example.com' })

      expect(response.code).to eq('200')
      expect(response['Access-Control-Allow-Origin']).to eq('https://example.com')
    end

    it 'does not add Allow-Origin for disallowed origins' do
      response = api_client.get('/multi/', { 'Origin' => 'https://evil.example' })

      expect(response.code).to eq('200')
      expect(response['Access-Control-Allow-Origin']).to be_nil
    end
  end

  describe 'mount without CORS' do
    it 'does not add CORS headers', :aggregate_failures do
      response = api_client.get('/app/', { 'Origin' => 'https://example.com' })

      expect(response.code).to eq('200')
      expect(response['Access-Control-Allow-Origin']).to be_nil
    end
  end
end
