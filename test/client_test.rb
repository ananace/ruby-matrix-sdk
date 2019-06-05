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

  def test_state_handling
    cl = MatrixSdk::Client.new 'https://example.com'
    room = '!roomid:example.com'
    cl.send :ensure_room, room

    cl.api.expects(:get_room_members).returns(chunk: [])
    cl.api.expects(:get_room_name).raises MatrixSdk::MatrixNotFoundError.new({ errcode: 404, error: '' }, 404)

    assert_equal 'Empty Room', cl.rooms.first.display_name
    cl.send(:handle_state, room, type: 'm.room.member', content: { membership: 'join', displayname: 'Alice' }, state_key: '@alice:example.com')
    assert_equal 'Alice', cl.rooms.first.display_name
    cl.send(:handle_state, room, type: 'm.room.member', content: { membership: 'join', displayname: 'Bob' }, state_key: '@bob:example.com')
    assert_equal 'Alice and Bob', cl.rooms.first.display_name
    cl.send(:handle_state, room, type: 'm.room.member', content: { membership: 'join', displayname: 'Charlie' }, state_key: '@charlie:example.com')
    assert_equal 'Alice and 2 others', cl.rooms.first.display_name
    cl.send(:handle_state, room, type: 'm.room.member', content: { membership: 'kick' }, state_key: '@charlie:example.com')
    assert_equal 'Alice and Bob', cl.rooms.first.display_name

    cl.send(:handle_state, room, type: 'm.room.canonical_alias', content: { alias: '#test:example.com' })
    assert_equal '#test:example.com', cl.rooms.first.canonical_alias
    assert_equal '#test:example.com', cl.rooms.first.display_name
    cl.send(:handle_state, room, type: 'm.room.name', content: { name: 'Test room' })
    assert_equal 'Test room', cl.rooms.first.display_name
    cl.send(:handle_state, room, type: 'm.room.topic', content: { topic: 'Test room' })
    assert_equal 'Test room', cl.rooms.first.topic
    cl.send(:handle_state, room, type: 'm.room.aliases', content: { aliases: ['#test:example1.com'] })
    assert cl.rooms.first.aliases.include? '#test:example1.com'
    assert cl.rooms.first.aliases.include? '#test:example.com'
    cl.send(:handle_state, room, type: 'm.room.join_rules', content: { join_rule: :invite })
    assert cl.rooms.first.invite_only?
    cl.send(:handle_state, room, type: 'm.room.guest_access', content: { guest_access: :can_join })
    assert cl.rooms.first.guest_access?

    expected_room = cl.rooms.first

    assert_equal expected_room, cl.find_room('#test:example1.com')
    assert_equal expected_room, cl.find_room('#test:example.com')
    assert_equal expected_room, cl.find_room(room)
  end

  def test_login
    cl = MatrixSdk::Client.new 'https://example.com'
    cl.api.expects(:login).with(user: 'alice', password: 'password').returns(user_id: '@alice:example.com', access_token: 'opaque', device_id: 'device', home_server: 'example.com')
    cl.expects(:sync)

    cl.login('alice', 'password')

    assert cl.logged_in?
    assert_equal '@alice:example.com', cl.mxid

    cl.api.expects(:logout)
    cl.logout

    assert !cl.logged_in?
    assert_not_equal '@alice:example.com', cl.mxid
  end

  def test_token_login
    cl = MatrixSdk::Client.new 'https://example.com'
    cl.api.expects(:login).with(user: 'alice', token: 'token', type: 'm.login.token').returns(user_id: '@alice:example.com', access_token: 'opaque', device_id: 'device', home_server: 'example.com')
    cl.expects(:sync)

    cl.login_with_token('alice', 'token')

    assert cl.logged_in?
    assert_equal '@alice:example.com', cl.mxid
  end

  def test_register
    cl = MatrixSdk::Client.new 'https://example.com'
    cl.api.expects(:register).with(username: 'alice', password: 'password', auth: { type: 'm.login.dummy' }).returns(user_id: '@alice:example.com', access_token: 'opaque', device_id: 'device', home_server: 'example.com')
    cl.expects(:sync)

    cl.register_with_password('alice', 'password')

    assert cl.logged_in?
    assert_equal '@alice:example.com', cl.mxid
  end

  def test_threading
    cl = MatrixSdk::Client.new 'https://example.com'
    cl.expects(:sync)
      .twice.raises(MatrixSdk::MatrixRequestError.new({ errcode: 503, error: '' }, 503))
      .then.returns({})

    cl.start_listener_thread sync_interval: 0.05, bad_sync_timeout: 0
    sleep 0.01
    cl.stop_listener_thread
  end
end
