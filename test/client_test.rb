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

  def test_sync_retry
    cl = MatrixSdk::Client.new 'https://example.com'
    cl.api.expects(:sync)
      .times(2).raises(MatrixSdk::MatrixTimeoutError)
      .then.returns(presence: { events: [] }, rooms: { invite: [], leave: [], join: [] }, next_batch: '0')

    cl.sync(allow_sync_retry: 5)
  end

  def test_sync_limited_retry
    cl = MatrixSdk::Client.new 'https://example.com'
    cl.api.expects(:sync).times(5).raises(MatrixSdk::MatrixTimeoutError)

    assert_raises(MatrixSdk::MatrixTimeoutError) { cl.sync(allow_sync_retry: 5) }
  end

  def test_events
    cl = MatrixSdk::Client.new 'https://example.com'


    cl.instance_variable_get(:@on_presence_event).expects(:fire).once
    cl.instance_variable_get(:@on_invite_event).expects(:fire).once
    cl.instance_variable_get(:@on_leave_event).expects(:fire).once
    cl.instance_variable_get(:@on_event).expects(:fire).twice
    cl.instance_variable_get(:@on_ephemeral_event).expects(:fire).once

    response = JSON.parse(open('test/fixtures/sync_response.json').read, symbolize_names: true)

    cl.send :handle_sync_response, response
  end

  def test_sync_results
    cl = MatrixSdk::Client.new 'https://example.com'
    response = JSON.parse(open('test/fixtures/sync_response.json').read, symbolize_names: true)

    cl.instance_variable_get(:@on_ephemeral_event)
      .expects(:fire).with do |ev|
      wanted = { type: 'm.typing', content: { user_ids: ['@alice:example.com'] }, room_id: '!726s6s6q:example.com' }
      ev.event == wanted
    end

    cl.send :handle_sync_response, response

    assert_equal 1, cl.rooms.count

    room = cl.rooms.first
    assert_equal '!726s6s6q:example.com', room.id
    assert_equal 2, room.events.count
    assert_equal 'I am a fish', room.events.last[:content][:body]
    assert_equal '@alice:example.com', room.events.last[:sender]
    assert_equal 2, room.members.count
    assert_equal '@alice:example.com', room.members.first.id
    assert_equal '@bob:example.com', room.members.last.id

    cl.api.expects(:get_avatar_url).with('@alice:example.com').returns(avatar_url: 'mxc://example')
    cl.api.expects(:get_display_name).with('@alice:example.com').returns(displayname: 'Alice')

    assert_equal 'mxc://example', room.members.first.avatar_url
    assert_equal 'Alice', room.members.first.display_name

    # Ensure room-specific member updates don't escape the room context
    assert_nil cl.get_user('@alice:example.com').instance_variable_get(:@avatar_url)
    assert_nil cl.get_user('@alice:example.com').instance_variable_get(:@display_name)
  end
end
