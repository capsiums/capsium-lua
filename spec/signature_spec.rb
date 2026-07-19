require_relative 'spec_helper'

RSpec.describe 'Digital signatures (ARCHITECTURE.md §6a)' do
  describe 'correctly signed package' do
    it 'is served normally', :aggregate_failures do
      response = api_client.get('/signed/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to include('Signed sample package')
    end

    it 'is reported valid by content-validity (signature verified)',
       :aggregate_failures do
      response = api_client.get('/api/v1/introspect/content-validity')
      data = parse_json(response)

      entry = data['contentValidity'].find do |e|
        e['package'] == 'signed-sample-1.0.0'
      end

      expect(entry).not_to be_nil
      expect(entry['valid']).to be(true)
      expect(entry['lastChecked']).to be_a(String)
    end
  end

  describe 'package with a non-matching signature' do
    it 'is rejected with 5xx and a signature reason', :aggregate_failures do
      response = api_client.get('/signed-broken/')

      expect(response.code.to_i).to be >= 500
      expect(response['Content-Type']).to include('application/json')

      data = parse_json(response)
      expect(data['error']).to match(/signature/i)
    end

    it 'is reported invalid by content-validity with a signature reason',
       :aggregate_failures do
      response = api_client.get('/api/v1/introspect/content-validity')
      data = parse_json(response)

      entry = data['contentValidity'].find do |e|
        e['package'] == 'signed-tampered-1.0.0'
      end

      expect(entry).not_to be_nil
      expect(entry['valid']).to be(false)
      expect(entry['reason']).to match(/signature/i)
      expect(entry['lastChecked']).to be_a(String)
    end

    it 'is also rejected on its auto-mount' do
      response = api_client.get('/capsium/signed-tampered-1.0.0/')

      expect(response.code.to_i).to be >= 500
    end
  end
end
