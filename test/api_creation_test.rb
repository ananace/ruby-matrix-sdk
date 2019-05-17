require 'test_helper'

require 'net/http'
require 'resolv'

class ApiTest < Test::Unit::TestCase
  def test_creation
    api = MatrixSdk::Api.new 'https://matrix.example.com/_matrix/'
    assert_equal URI('https://matrix.example.com'), api.homeserver

    api = MatrixSdk::Api.new 'matrix.com'
    assert_equal URI('https://matrix.com'), api.homeserver
  end

  def test_creation_with_as_protocol
    api = MatrixSdk::Api.new 'https://matrix.example.com', protocols: :AS

    assert api.protocol? :AS
    # Ensure CS protocol is also provided
    assert api.respond_to? :join_room
  end

  def test_creation_with_cs_protocol
    api = MatrixSdk::Api.new 'https://matrix.example.com'

    assert api.respond_to? :join_room
    # assert !api.respond_to?(:identity_status) # No longer true since the definite include
  end

  def test_creation_with_is_protocol
    api = MatrixSdk::Api.new 'https://matrix.example.com', protocols: :IS

    # assert !api.respond_to?(:join_room) # No longer true since the definite include
    assert api.respond_to? :identity_status
  end

  def test_fail_creation
    assert_raises(ArgumentError) { MatrixSdk::Api.new :test }
    assert_raises(ArgumentError) { MatrixSdk::Api.new URI() }
  end

  # This test is more complicated due to testing protocol extensions and auto-login all in the initializer
  def test_creation_with_login
    MatrixSdk::Api
      .any_instance
      .expects(:request)
      .with(:post, :client_r0, '/login',
            body: {
              type: 'm.login.password',
              initial_device_display_name: MatrixSdk::Api::USER_AGENT,
              user: 'user',
              password: 'pass'
            },
            query: {})
      .returns(MatrixSdk::Response.new(nil, token: 'token', device_id: 'device id'))

    api = MatrixSdk::Api.new 'https://user:pass@matrix.example.com/_matrix/'

    assert_equal URI('https://matrix.example.com'), api.homeserver
  end

  def test_client_creation_for_domain
    ::Resolv::DNS
      .any_instance
      .expects(:getresource)
      .never

    ::Net::HTTP
      .expects(:get)
      .with('https://example.com/.well-known/matrix/client')
      .returns('{"m.homeserver":{"base_url":"https://matrix.example.com"}}')

    MatrixSdk::Api
      .expects(:new)
      .with(URI('https://matrix.example.com'), address: 'matrix.example.com', port: 443)

    MatrixSdk::Api.new_for_domain 'example.com', target: :client
  end

  def test_server_creation_for_domain
    ::Resolv::DNS
      .any_instance
      .expects(:getresource)
      .returns(Resolv::DNS::Resource::IN::SRV.new(10, 1, 443, 'matrix.example.com'))

    MatrixSdk::Api
      .expects(:new)
      .with(URI('https://example.com'), address: 'matrix.example.com', port: 443)

    MatrixSdk::Api.new_for_domain 'example.com', target: :server
  end

  def test_server_creation_for_missing_domain
    ::Resolv::DNS
      .any_instance
      .expects(:getresource)
      .raises(::Resolv::ResolvError)

    MatrixSdk::Api
      .expects(:new)
      .with(URI('https://example.com'), address: 'example.com', port: 8448)

    MatrixSdk::Api.new_for_domain 'example.com', target: :server
  end

  def test_server_creation_for_domain_and_port
    MatrixSdk::Api
      .expects(:new)
      .with(URI('https://example.com'), address: 'example.com', port: 8448)

    MatrixSdk::Api.new_for_domain 'example.com:8448', target: :server
  end

  def test_failed_creation_with_domain
    ::Resolv::DNS
      .any_instance
      .stubs(:getresource)
      .raises(::Resolv::ResolvError)

    ::Net::HTTP
      .expects(:get)
      .with('https://example.com/.well-known/matrix/server')
      .raises(StandardError)
    ::Net::HTTP
      .expects(:get)
      .with('https://example.com/.well-known/matrix/client')
      .raises(StandardError)

    api = MatrixSdk::Api.new_for_domain('example.com', target: :server)
    assert_equal 'https://example.com', api.homeserver.to_s
    assert_equal 'example.com', api.connection_address
    assert_equal 8448, api.connection_port

    api = MatrixSdk::Api.new_for_domain('example.com', target: :client)
    assert_equal 'https://example.com', api.homeserver.to_s
    assert_equal 'example.com', api.connection_address
    assert_equal 8448, api.connection_port
  end

  def test_http_request_logging
    api = MatrixSdk::Api.new 'https://example.com'
    api.logger.expects(:debug?).returns(true)

    api.logger.stubs(:debug).with do |arg|
      [
        '> Sending a GET request to `https://example.com`:',
        '> accept-encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
        '> accept: */*',
        '> user-agent: Ruby',
        '>'
      ].include? arg
    end

    api.send :print_http, Net::HTTP::Get.new('https://example.com')
  end

  def test_http_response_logging
    api = MatrixSdk::Api.new 'https://example.com'
    api.logger.expects(:debug?).returns(true)

    api.logger.stubs(:debug).with do |arg|
      [
        '< Received a 200 GET response:',
        '<'
      ].include? arg
    end

    response = Net::HTTPSuccess.new(nil, 200, 'GET')
    response.instance_variable_set :@socket, nil
    api.send :print_http, response
  end

  def test_requests
    Net::HTTP.any_instance.stubs(:start)

    response = Net::HTTPSuccess.new(nil, 200, 'GET')
    response.stubs(:body).returns({ user_id: '@alice:example.com' }.to_json)

    api = MatrixSdk::Api.new 'https://example.com'
    http = api.send(:http)

    http.expects(:request).returns(response)
    assert_equal({ user_id: '@alice:example.com' }, api.request(:get, :client_r0, '/account/whoami'))

    err = Net::HTTPTooManyRequests.new(nil, 200, 'GET')
    err.stubs(:body).returns({ error: { retry_after_ms: 1500 } }.to_json)
    http.expects(:request).twice.returns(err).then.returns(response)
    api.expects(:sleep).with(1.5)

    assert_equal({ user_id: '@alice:example.com' }, api.request(:get, :client_r0, '/account/whoami'))
  end

  def test_http_changes
    Net::HTTP.any_instance.stubs(:start)
    Net::HTTP.any_instance.expects(:finish).never
    api = MatrixSdk::Api.new 'https://example.com'

    api.read_timeout = 5
    assert_equal 5, api.read_timeout

    api.validate_certificate = true
    assert_equal true, api.validate_certificate

    api.homeserver = URI('https://matrix.example.com')
    assert_equal 'matrix.example.com', api.homeserver.host

    http = api.send :http

    assert_equal 5, http.read_timeout
    assert_equal OpenSSL::SSL::VERIFY_NONE, http.verify_mode

    api = MatrixSdk::Api.new 'https://example.com'

    api.send(:http).expects(:finish).times(3)

    api.read_timeout = 5
    assert_equal 5, api.read_timeout

    api.validate_certificate = true
    assert_equal true, api.validate_certificate

    api.homeserver = URI('https://matrix.example.com')
    assert_equal 'matrix.example.com', api.homeserver.host
  end
end
