require 'net/http'
require 'uri'
require 'json'

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end

# API Client helper
class ApiClient
  attr_reader :base_url

  def initialize(base_url = 'http://localhost:8080')
    @base_url = base_url
  end

  def get(path, headers = {})
    uri = URI.join(base_url, path)
    request = Net::HTTP::Get.new(uri, headers)

    Net::HTTP.start(uri.hostname, uri.port) do |http|
      http.request(request)
    end
  end

  def get_with_host(path, host)
    get(path, { 'Host' => host })
  end
end

# Helper to parse JSON response
def parse_json(response)
  JSON.parse(response.body)
end

# Global API client
def api_client
  @api_client ||= ApiClient.new
end
