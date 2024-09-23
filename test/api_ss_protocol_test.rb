require 'test_helper'

class ApiSSTest < Test::Unit::TestCase
  def setup
    super

    @api = MatrixSdk::Api.new 'https://example.com', protocols: :SS, threadsafe: false
  end

  def test_api_server_version
    stub_request(:get, 'https://example.com/_matrix/federation/v1/version').to_return_json(
      body: {
        server: {
          name: 'Synapse',
          version: 'Example'
        }
      }
    )
    assert_equal 'Synapse Example', @api.server_version.to_s
  end
end
