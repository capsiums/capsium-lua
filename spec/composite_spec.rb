require_relative 'spec_helper'

RSpec.describe 'Composite packages (ARCHITECTURE.md §4a)' do
  it 'serves the dependent package’s own content' do
    response = api_client.get('/composite/')

    expect(response.code).to eq('200')
    expect(response.body).to include('Composite sample package')
  end

  it 'resolves the dependency from the store (newest satisfying version)',
     :aggregate_failures do
    response = api_client.get('/composite/vendor/app.js')

    expect(response.code).to eq('200')
    expect(response['Content-Type']).to include('text/javascript')
    expect(response.body).to include('vendor core 1.1.0')
    expect(response.body).not_to include('1.0.0')
  end

  it 'serves a remapped route at the remap path only', :aggregate_failures do
    remapped = api_client.get('/composite/vendor/legacy-app.js')
    original = api_client.get('/composite/vendor/old-app.js')

    expect(remapped.code).to eq('200')
    expect(remapped.body).to include('vendor core 1.1.0')
    expect(original.code).to eq('404')
  end

  it 'adds responseHeaders to inherited routes', :aggregate_failures do
    response = api_client.get('/composite/vendor/greeting')

    expect(response.code).to eq('200')
    expect(response.body).to include('hello from vendor core')
    expect(response['X-From']).to eq('composite')
  end

  it 'rewrites body and headers with responseRewrite',
     :aggregate_failures do
    response = api_client.get('/composite/vendor/rewritten')

    expect(response.code).to eq('200')
    expect(response.body).to eq('rewritten by composite')
    expect(response['X-Rewritten']).to eq('yes')
  end

  it 'rejects references to a dependency’s private resource' do
    response = api_client.get('/composite/vendor/secret.txt')

    expect(response.code).to eq('404')
  end
end
