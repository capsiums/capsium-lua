require_relative 'spec_helper'

RSpec.describe 'Package integrity (ARCHITECTURE.md §6)' do
  describe 'tampered package' do
    it 'is rejected with 5xx and a reason when served', :aggregate_failures do
      response = api_client.get('/broken/')

      expect(response.code.to_i).to be >= 500
      expect(response['Content-Type']).to include('application/json')

      data = parse_json(response)
      expect(data['error']).to match(/checksum mismatch/i)
    end

    it 'is reported invalid by content-validity', :aggregate_failures do
      response = api_client.get('/api/v1/introspect/content-validity')
      data = parse_json(response)

      entry = data['contentValidity'].find do |e|
        e['package'] == 'canonical-tampered-1.0.0'
      end

      expect(entry).not_to be_nil
      expect(entry['valid']).to be(false)
      expect(entry['reason']).to match(/checksum mismatch/i)
      expect(entry['lastChecked']).to be_a(String)
    end

    it 'does not serve the tampered package on its auto-mount either' do
      response = api_client.get('/capsium/canonical-tampered-1.0.0/')

      expect(response.code.to_i).to be >= 500
    end
  end

  describe 'content hashes' do
    it 'returns SHA-256 hex digests of the .cap blobs', :aggregate_failures do
      response = api_client.get('/api/v1/introspect/content-hashes')
      data = parse_json(response)

      expect(data['contentHashes']).not_to be_empty
      data['contentHashes'].each do |entry|
        expect(entry['hash']).to match(/\A[0-9a-f]{64}\z/)
      end
    end

    it 'matches the locally computed digest of the fixture blob' do
      expected = Digest::SHA256.file(
        File.join(__dir__, 'fixtures/canonical-sample-1.0.0.cap')).hexdigest

      response = api_client.get('/api/v1/introspect/content-hashes')
      data = parse_json(response)
      entry = data['contentHashes'].find do |e|
        e['package'] == 'canonical-sample-1.0.0'
      end

      expect(entry).not_to be_nil
      expect(entry['hash']).to eq(expected)
    end
  end
end
