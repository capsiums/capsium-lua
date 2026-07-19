require_relative 'spec_helper'

RSpec.describe 'Multiple packages' do
  describe 'second configured mount' do
    it 'serves the multi-test package at /multi', :aggregate_failures do
      response = api_client.get('/multi/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
    end

    it 'serves the same package on its auto-mount', :aggregate_failures do
      response = api_client.get('/capsium/multi-test-1.0.0/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
    end
  end

  describe 'introspection across packages' do
    it 'reports all packages in metadata', :aggregate_failures do
      response = api_client.get('/api/v1/introspect/metadata')
      data = parse_json(response)

      names = data['packages'].map { |p| p['name'] }
      expect(names).to include('mn-samples-iso', 'multi-test',
                             'canonical-sample', 'dormant-package')
    end

    it 'reports routes per package', :aggregate_failures do
      response = api_client.get('/api/v1/introspect/routes')
      data = parse_json(response)

      packages = data['routes'].map { |r| r['package'] }
      expect(packages).to include('mn-samples-iso-0.1.0', 'multi-test-1.0.0')
    end
  end
end
