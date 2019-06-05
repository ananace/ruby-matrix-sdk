require 'test_helper'

class ApiSSTest < Test::Unit::TestCase
  def setup
    @http = mock
    @http.stubs(:active?).returns(true)

    @api = MatrixSdk::Api.new 'https://example.com', protocols: :SS
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)
  end

  def mock_success(body)
    response = mock
    response.stubs(:is_a?).with(Net::HTTPTooManyRequests).returns(false)
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    response.stubs(:body).returns(body)
    response
  end

  def test_api_server_version
    @http.expects(:request).returns(mock_success('{"server":{"name":"Synapse","version":"0.99.5.2"}}'))
    assert_equal 'Synapse 0.99.5.2', @api.server_version.to_s
  end
end
