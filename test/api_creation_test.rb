require 'test_helper'

require 'net/http'
require 'resolv'

class ApiTest < Test::Unit::TestCase
  def test_creation
    api = MatrixSdk::Api.new 'https://matrix.example.com/_matrix/'

    assert_equal URI('https://matrix.example.com'), api.homeserver
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
    assert !api.respond_to?(:identity_status)
  end

  def test_creation_with_is_protocol
    api = MatrixSdk::Api.new 'https://matrix.example.com', protocols: :IS

    assert !api.respond_to?(:join_room)
    assert api.respond_to? :identity_status
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
end
