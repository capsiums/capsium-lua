require_relative 'spec_helper'

RSpec.describe 'Encrypted packages (ARCHITECTURE.md §6b)' do
  describe 'with the correct key configured (reactor-level default)' do
    it 'decrypts and serves the package', :aggregate_failures do
      response = api_client.get('/encrypted/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to include('Encrypted sample package')
    end

    it 'verifies the inner package integrity (content-validity)',
       :aggregate_failures do
      response = api_client.get('/api/v1/introspect/content-validity')
      data = parse_json(response)

      entry = data['contentValidity'].find do |e|
        e['package'] == 'encrypted-sample-1.0.0'
      end

      expect(entry).not_to be_nil
      expect(entry['valid']).to be(true)
      expect(entry['lastChecked']).to be_a(String)
    end

    it 'also decrypts on the auto-mount', :aggregate_failures do
      response = api_client.get('/capsium/encrypted-sample-1.0.0/')

      expect(response.code).to eq('200')
      expect(response.body).to include('Encrypted sample package')
    end
  end

  describe 'with the wrong key configured (per-mount override)' do
    it 'is rejected with 5xx and a decryption reason', :aggregate_failures do
      response = api_client.get('/encrypted-wrong-key/')

      expect(response.code.to_i).to be >= 500
      expect(response['Content-Type']).to include('application/json')

      data = parse_json(response)
      expect(data['error']).to match(/unwrap|decrypt|key/i)
    end
  end
end
