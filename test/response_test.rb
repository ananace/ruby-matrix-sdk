# frozen_string_literal: true

require 'test_helper'

class ResponseTest < Test::Unit::TestCase
  def setup
    @http = mock
    @http.stubs(:active?).returns(true)

    @api = MatrixSdk::Api.new 'https://example.com'
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)
  end

  def test_creation
    data = { test_key: 'value' }
    response = MatrixSdk::Response.new(@api, data)

    assert_equal @api, response.api
    assert_equal 'value', response.test_key
  end

  def test_creation_failure
    data = 'Something else'
    assert_raises(ArgumentError) { MatrixSdk::Response.new(@api, data) }
  end
end
