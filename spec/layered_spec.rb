require_relative 'spec_helper'

RSpec.describe 'Layered storage (ARCHITECTURE.md §5a)' do
  it 'resolves top-to-bottom: the top layer wins', :aggregate_failures do
    response = api_client.get('/layered/')

    expect(response.code).to eq('200')
    expect(response.body).to include('updates layer')
    expect(response.body).not_to include('base layer')
  end

  it 'falls through to lower layers for files only they have' do
    response = api_client.get('/layered/base-only')

    expect(response.code).to eq('200')
    expect(response.body).to include('Base-only page')
  end

  it 'resolves 404 for tombstoned paths even though the base layer has them' do
    response = api_client.get('/layered/deprecated')

    expect(response.code).to eq('404')
  end

  it 'resolves 404 for files in no layer' do
    response = api_client.get('/layered/no-such-page')

    expect(response.code).to eq('404')
  end

  it 'stays integrity-valid with layers and a tombstone list',
     :aggregate_failures do
    response = api_client.get('/api/v1/introspect/content-validity')
    data = parse_json(response)

    entry = data['contentValidity'].find do |e|
      e['package'] == 'layered-sample-1.0.0'
    end

    expect(entry).not_to be_nil
    expect(entry['valid']).to be(true)
  end
end
