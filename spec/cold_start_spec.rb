require_relative 'spec_helper'

# The dormant package is never requested through a mount anywhere in the
# suite: these specs prove the introspection endpoints lazily extract and
# load packages on demand (a cold reactor still reports everything).
RSpec.describe 'Cold-start introspection' do
  it 'reports metadata for packages never requested via a mount' do
    response = api_client.get('/api/v1/introspect/metadata')
    data = parse_json(response)

    entry = data['packages'].find { |p| p['name'] == 'dormant-package' }

    expect(entry).not_to be_nil
    expect(entry['version']).to eq('0.1.0')
  end

  it 'reports routes for packages never requested via a mount' do
    response = api_client.get('/api/v1/introspect/routes')
    data = parse_json(response)

    entry = data['routes'].find { |r| r['package'] == 'dormant-package-0.1.0' }

    expect(entry).not_to be_nil
    paths = entry['routes'].map { |r| r['path'] }
    expect(paths).to include('/')
    expect(entry['routes'].map { |r| r['method'] }.uniq).to eq(['GET'])
  end

  it 'reports content hashes for packages never requested via a mount' do
    response = api_client.get('/api/v1/introspect/content-hashes')
    data = parse_json(response)

    entry = data['contentHashes'].find do |h|
      h['package'] == 'dormant-package-0.1.0'
    end

    expect(entry).not_to be_nil
    expect(entry['hash']).to match(/\A[0-9a-f]{64}\z/)
  end

  it 'reports content validity for packages never requested via a mount',
     :aggregate_failures do
    response = api_client.get('/api/v1/introspect/content-validity')
    data = parse_json(response)

    entry = data['contentValidity'].find do |v|
      v['package'] == 'dormant-package-0.1.0'
    end

    expect(entry).not_to be_nil
    expect(entry['valid']).to be(true)
    expect(entry['lastChecked']).to be_a(String)
  end
end
