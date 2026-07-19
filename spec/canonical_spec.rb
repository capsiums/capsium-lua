require_relative 'spec_helper'

RSpec.describe 'Canonical-format package' do
  describe 'index routes (auto-generated from manifest)' do
    it 'serves the index at the mount root', :aggregate_failures do
      response = api_client.get('/canonical/')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/html')
      expect(response.body).to include('Canonical sample package')
    end

    it 'serves the index at /index and /index.html (dual routes)' do
      root = api_client.get('/canonical/')
      index = api_client.get('/canonical/index')
      index_html = api_client.get('/canonical/index.html')

      expect(index.code).to eq('200')
      expect(index_html.code).to eq('200')
      expect(root.body).to eq(index.body)
      expect(index.body).to eq(index_html.body)
    end
  end

  describe 'HTML dual routes' do
    it 'serves HTML pages at basename and full filename', :aggregate_failures do
      basename = api_client.get('/canonical/about')
      full = api_client.get('/canonical/about.html')

      expect(basename.code).to eq('200')
      expect(full.code).to eq('200')
      expect(basename.body).to include('About the canonical sample')
      expect(basename.body).to eq(full.body)
    end
  end

  describe 'static resources' do
    it 'serves JavaScript as text/javascript (RFC 9239)' do
      response = api_client.get('/canonical/app.js')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/javascript')
    end

    it 'serves CSS with a long-lived Cache-Control header', :aggregate_failures do
      response = api_client.get('/canonical/styles.css')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('text/css')
      expect(response['Cache-Control']).to eq('public, max-age=31536000')
    end
  end

  describe 'dataset routes' do
    it 'serves the dataset JSON under /api/v1/data/<id>', :aggregate_failures do
      response = api_client.get('/canonical/api/v1/data/animals')

      expect(response.code).to eq('200')
      expect(response['Content-Type']).to include('application/json')

      data = parse_json(response)
      expect(data).to be_an(Array)
      expect(data.map { |a| a['name'] }).to include('cat', 'dog', 'spider')
    end

    it 'returns 404 for unknown datasets' do
      response = api_client.get('/canonical/api/v1/data/nope')

      expect(response.code).to eq('404')
    end
  end

  describe 'auto-mount' do
    it 'is also served at /capsium/<name>', :aggregate_failures do
      response = api_client.get('/capsium/canonical-sample-1.0.0/')

      expect(response.code).to eq('200')
      expect(response.body).to include('Canonical sample package')
    end
  end

  describe 'introspection' do
    it 'reports the package as valid (checksums verified)', :aggregate_failures do
      response = api_client.get('/api/v1/introspect/content-validity')
      data = parse_json(response)

      entry = data['contentValidity'].find do |e|
        e['package'] == 'canonical-sample'
      end

      expect(entry).not_to be_nil
      expect(entry['valid']).to be(true)
      expect(entry['lastChecked']).to be_a(String)
    end
  end
end
