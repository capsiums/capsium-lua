require_relative 'spec_helper'

RSpec.describe 'Capsium Packages' do
  describe 'package access' do
    it 'allows access to Capsium packages' do
      response = api_client.get('/capsium/mn-samples-iso-0.1.0/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to include('ISO sample documents in Metanorma')
    end
  end

  describe 'HTML files in packages' do
    it 'serves HTML files correctly' do
      response = api_client.get('/capsium/mn-samples-iso-0.1.0/documents/technical-report/document.html')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to match(/ISO|Technical Report/)
    end
  end

  describe 'XML files in packages' do
    it 'serves XML files correctly' do
      response = api_client.get('/capsium/mn-samples-iso-0.1.0/documents.xml')

      expect(response.code).to eq('200')
      expect(response['Content-Type'].downcase).to include('xml')
      expect(response.body).to match(/<\?xml|</)
    end
  end

  describe 'nonexistent packages' do
    it 'returns 404 for nonexistent packages' do
      response = api_client.get('/capsium/nonexistent-package/')

      expect(response.code).to eq('404')
    end
  end

  describe 'nonexistent files in packages' do
    it 'returns 404 for nonexistent files' do
      response = api_client.get('/capsium/mn-samples-iso-0.1.0/nonexistent.html')

      expect(response.code).to eq('404')
    end
  end

  describe 'package index routes' do
    it 'serves the same content for different index routes' do
      response1 = api_client.get('/capsium/mn-samples-iso-0.1.0/')
      response2 = api_client.get('/capsium/mn-samples-iso-0.1.0/index')
      response3 = api_client.get('/capsium/mn-samples-iso-0.1.0/index.html')

      expect(response1.code).to eq('200')
      expect(response2.code).to eq('200')
      expect(response3.code).to eq('200')

      expect(response1.body).to eq(response2.body)
      expect(response2.body).to eq(response3.body)
    end
  end
end
