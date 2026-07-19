require_relative 'spec_helper'
require 'base64'

RSpec.describe 'Basic authentication (ARCHITECTURE.md §4b)' do
  def basic_auth(user, password)
    { 'Authorization' => "Basic #{Base64.strict_encode64("#{user}:#{password}")}" }
  end

  it 'challenges unauthenticated requests with 401 + WWW-Authenticate',
     :aggregate_failures do
    response = api_client.get('/auth-basic/')

    expect(response.code).to eq('401')
    expect(response['WWW-Authenticate']).to eq('Basic realm="capsium-test"')
  end

  it 'rejects invalid credentials' do
    response = api_client.get('/auth-basic/', basic_auth('admin', 'wrong'))

    expect(response.code).to eq('401')
  end

  it 'serves content with valid apr1 credentials' do
    response = api_client.get('/auth-basic/',
                              basic_auth('admin', 's3cret-Passw0rd!'))

    expect(response.code).to eq('200')
    expect(response.body).to include('Authenticated area')
  end

  it 'verifies {SHA} credentials' do
    response = api_client.get('/auth-basic/',
                              basic_auth('sunny', 's3cret-Passw0rd!'))

    expect(response.code).to eq('200')
  end

  it 'verifies bcrypt credentials' do
    response = api_client.get('/auth-basic/',
                              basic_auth('betty', 's3cret-Passw0rd!'))

    expect(response.code).to eq('200')
  end

  it 'verifies DES crypt credentials' do
    response = api_client.get('/auth-basic/',
                              basic_auth('diesel', 'secret123'))

    expect(response.code).to eq('200')
  end

  describe 'dataset accessControl' do
    it 'allows any authenticated principal when only authentication is required' do
      response = api_client.get('/auth-basic/api/v1/data/secure',
                                basic_auth('admin', 's3cret-Passw0rd!'))

      expect(response.code).to eq('200')
      expect(parse_json(response).first['name']).to eq('confidential-cat')
    end

    it 'answers 401 for an authenticationRequired route without credentials' do
      response = api_client.get('/auth-basic/api/v1/data/secure')

      expect(response.code).to eq('401')
    end

    it 'answers 403 for role-gated routes (basic auth carries no roles)' do
      response = api_client.get('/auth-basic/api/v1/data/admin-data',
                                basic_auth('admin', 's3cret-Passw0rd!'))

      expect(response.code).to eq('403')
    end
  end
end
