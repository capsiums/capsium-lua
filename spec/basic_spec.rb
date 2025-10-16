require_relative 'spec_helper'

RSpec.describe 'Basic Server Functionality' do
  describe 'server running' do
    it 'responds to requests' do
      response = api_client.get('/')

      expect(response.code).to eq('200')
    end
  end

  describe 'static content' do
    it 'serves static content correctly' do
      response = api_client.get('/')

      expect(response.body).to include('Capsium Nginx Reactor')
    end
  end

  describe 'static files' do
    it 'serves HTML files with correct content type' do
      response = api_client.get('/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
    end

    it 'returns 404 for non-existent files' do
      response = api_client.get('/nonexistent.html')

      expect(response.code).to eq('404')
    end
  end

  describe 'nginx headers' do
    it 'sets expected server headers' do
      response = api_client.get('/')
      server_header = response['Server']&.downcase || ''

      expect(server_header).to match(/nginx|openresty/)
    end
  end
end
