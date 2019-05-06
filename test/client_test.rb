require 'test_helper'

class ClientTest < Test::Unit::TestCase
  def test_creation
    client = MatrixSdk::Client.new 'https://example.com'

    assert !client.api.nil?
    assert_equal client.api.homeserver, URI('https://example.com')
  end

  def test_api_creation
    api = MatrixSdk::Api.new 'https://example.com'
    client = MatrixSdk::Client.new api

    assert_equal client.api, api
  end

  def test_cache
    cl_all = MatrixSdk::Client.new 'https://example.com', client_cache: :all
    cl_some = MatrixSdk::Client.new 'https://example.com', client_cache: :some
    cl_none = MatrixSdk::Client.new 'https://example.com', client_cache: :none

    room_id = '!test:example.com'
    event = {
      type: 'm.room.member',
      state_key: '@user:example.com',
      content: {
        membership: 'join',
        displayname: 'User'
      }
    }

    cl_all.send :handle_state, room_id, event
    cl_some.send :handle_state, room_id, event
    cl_none.send :handle_state, room_id, event

    assert cl_none.instance_variable_get(:@rooms).empty?
    assert !cl_some.instance_variable_get(:@rooms).empty?
    assert !cl_all.instance_variable_get(:@rooms).empty?

    assert cl_none.instance_variable_get(:@users).empty?
    assert cl_some.instance_variable_get(:@users).empty?
    assert !cl_all.instance_variable_get(:@users).empty?
  end
end
