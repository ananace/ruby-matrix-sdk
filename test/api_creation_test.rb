require 'test_helper'

require 'resolv'

class ApiTest < Test::Unit::TestCase
  def test_creation
    api = MatrixSdk::Api.new 'https://matrix.example.com/_matrix/'

    assert_equal URI('https://matrix.example.com'), api.homeserver
  end

  def test_creation_with_login
    MatrixSdk::Api
      .any_instance
      .expects(:login)
      .with(user: 'user', password: 'pass')
      .returns true

    api = MatrixSdk::Api.new 'https://user:pass@matrix.example.com/_matrix/'

    assert_equal URI('https://matrix.example.com'), api.homeserver
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
