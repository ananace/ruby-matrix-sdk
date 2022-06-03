require 'test_helper'

class ApiTest < Test::Unit::TestCase
  def setup
    @http = mock
    @http.stubs(:active?).returns(true)

    @api = MatrixSdk::Api.new 'https://example.com', protocols: :CS, threadsafe: false
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)

    matrixsdk_add_api_stub
  end

  def mock_success(body)
    response = mock
    response.stubs(:is_a?).with(Net::HTTPTooManyRequests).returns(false)
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    response.stubs(:body).returns(body)
    response
  end

  def test_api_versions
    @http.expects(:request).returns(mock_success('{"versions":["r0.3.0","r0.4.0"]}'))
    assert_equal 'r0.4.0', @api.client_api_versions.latest
  end

  def test_api_unsable_features
    @http.expects(:request).returns(mock_success('{"unstable_features":{"lazy_loading_members": true}}'))
    assert_equal true, @api.client_api_unstable_features.has?(:lazy_loading_members)
  end

  def test_whoami
    @http.expects(:request).returns(mock_success('{"user_id":"@user:example.com"}'))
    assert_equal @api.whoami?, user_id: '@user:example.com'
  end

  def test_sync
    @http.expects(:request).with do |req|
      req.path == '/_matrix/client/r0/sync?timeout=30000'
    end.returns(mock_success('{}'))
    assert @api.sync
  end

  def test_sync_timeout
    @http.expects(:request).with do |req|
      req.path == '/_matrix/client/r0/sync?timeout=3000'
    end.returns(mock_success('{}'))

    assert @api.sync(timeout: 3)

    @http.expects(:request).with do |req|
      req.path == '/_matrix/client/r0/sync'
    end.returns(mock_success('{}'))

    assert @api.sync(timeout: nil)
  end

  def test_send_message
    @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/send/m.room.message/42', body: { msgtype: 'm.text', body: 'this is a message' }, query: {}).returns({})
    assert @api.send_message('!room:example.com', 'this is a message', txn_id: 42)
  end

  def test_send_emote
    @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/send/m.room.message/42', body: { msgtype: 'm.emote', body: 'this is an emote' }, query: {}).returns({})
    assert @api.send_emote('!room:example.com', 'this is an emote', txn_id: 42)
  end

  def test_redact_event
    @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/redact/%24eventid%3Aexample.com/42', body: {}, query: {}).returns({})
    assert @api.redact_event('!room:example.com', '$eventid:example.com', txn_id: 42)
  end

  def test_redact_event_w_reason
    @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/redact/%24eventid%3Aexample.com/42', body: { reason: 'oops' }, query: {}).returns({})
    assert @api.redact_event('!room:example.com', '$eventid:example.com', txn_id: 42, reason: 'oops')
  end

  def test_eventv3_slashes
    @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/redact/%24acR1l0raoZnm60CBwAVgqbZqoO%2FmYU81xysh1u7XcJk/42', body: { reason: 'oops' }, query: {}).returns({})
    assert @api.redact_event('!room:example.com', '$acR1l0raoZnm60CBwAVgqbZqoO/mYU81xysh1u7XcJk', txn_id: 42, reason: 'oops')
  end

  def test_query_handling
    Net::HTTP::Get.expects(:new).with('/_matrix/client/r0/sync?filter=%7B%22room%22%3A%7B%22timeline%22%3A%7B%22limit%22%3A20%7D%2C%22state%22%3A%7B%22lazy_load_members%22%3Atrue%7D%7D%7D&full_state=false&timeout=15000').raises(RuntimeError, 'Expectation succeeded')
    e = assert_raises(RuntimeError) { @api.sync(filter: '{"room":{"timeline":{"limit":20},"state":{"lazy_load_members":true}}}', full_state: false, timeout: 15) }
    assert_equal 'Expectation succeeded', e.message
  end

  def test_content
    room = '!test:example.com'
    type = 'm.room.message'
    url = 'mxc://example.com/data'
    msgtype = 'type'
    msgbody = 'Name of content'
    content = {
      url: url,
      msgtype: msgtype,
      body: msgbody,
      info: {}
    }

    expect_message(@api, :send_message_event, room, type, content)
    @api.send_content(room, url, msgbody, msgtype)

    msgtype.replace 'm.location'
    url.replace 'geo:12341234'

    content.delete :url
    content[:geo_uri] = url

    expect_message(@api, :send_message_event, room, type, content)
    @api.send_location(room, url, msgbody)

    content = {
      msgtype: msgtype,
      body: msgbody
    }

    msgtype.replace 'm.text'

    expect_message(@api, :send_message_event, room, type, content)
    @api.send_message(room, msgbody)

    msgtype.replace 'm.emote'

    expect_message(@api, :send_message_event, room, type, content)
    @api.send_emote(room, msgbody)

    msgtype.replace 'm.notice'

    expect_message(@api, :send_message_event, room, type, content)
    @api.send_notice(room, msgbody)
  end

  def test_specced_state
    id = '!room:example.com'

    expect_message(@api, :get_room_state, id, 'm.room.name')
    @api.get_room_name(id)

    expect_message(@api, :send_state_event, id, 'm.room.name', { name: 'Room name' })
    @api.set_room_name(id, 'Room name')

    expect_message(@api, :get_room_state, id, 'm.room.topic')
    @api.get_room_topic(id)

    expect_message(@api, :send_state_event, id, 'm.room.topic', { topic: 'Room topic' })
    @api.set_room_topic(id, 'Room topic')

    expect_message(@api, :get_room_state, id, 'm.room.avatar')
    @api.get_room_avatar(id)

    expect_message(@api, :send_state_event, id, 'm.room.avatar', { url: 'Room avatar' })
    @api.set_room_avatar(id, 'Room avatar')

    expect_message(@api, :get_room_state, id, 'm.room.pinned_events')
    @api.get_room_pinned_events(id)

    expect_message(@api, :send_state_event, id, 'm.room.pinned_events', { pinned: ['event'] })
    @api.set_room_pinned_events(id, ['event'])

    expect_message(@api, :get_room_state, id, 'm.room.power_levels')
    @api.get_room_power_levels(id)

    expect_message(@api, :send_state_event, id, 'm.room.power_levels', { level: 1, events: {} })
    @api.set_room_power_levels(id, { level: 1 })

    expect_message(@api, :get_room_state, id, 'm.room.join_rules')
    @api.get_room_join_rules(id)

    expect_message(@api, :send_state_event, id, 'm.room.join_rules', { join_rule: :public })
    @api.set_room_join_rules(id, :public)

    expect_message(@api, :get_room_state, id, 'm.room.guest_access')
    @api.get_room_guest_access(id)

    expect_message(@api, :send_state_event, id, 'm.room.guest_access', { guest_access: :forbidden })
    @api.set_room_guest_access(id, :forbidden)

    expect_message(@api, :get_room_state, id, 'm.room.create')
    @api.get_room_creation_info(id)

    expect_message(@api, :get_room_state, id, 'm.room.encryption')
    @api.get_room_encryption_settings(id)

    expect_message(@api, :send_state_event, id, 'm.room.encryption', { algorithm: 'm.megolm.v1.aes-sha2', rotation_period_ms: 604_800_000, rotation_period_msgs: 100 })
    @api.set_room_encryption_settings(id)

    expect_message(@api, :get_room_state, id, 'm.room.history_visibility')
    @api.get_room_history_visibility(id)

    expect_message(@api, :send_state_event, id, 'm.room.history_visibility', { history_visibility: :anyone })
    @api.set_room_history_visibility(id, :anyone)

    expect_message(@api, :get_room_state, id, 'm.room.server_acl')
    @api.get_room_server_acl(id)

    expect_message(@api, :send_state_event, id, 'm.room.server_acl', { allow_ip_literals: false, allow: [], deny: [] })
    @api.set_room_server_acl(id, allow: [], deny: [])
  end

  def test_download_url
    assert_equal 'https://example.com/_matrix/media/r0/download/example.com/media', @api.get_download_url('mxc://example.com/media').to_s
    assert_equal 'https://matrix.org/_matrix/media/r0/download/example.com/media', @api.get_download_url('mxc://example.com/media', source: 'matrix.org').to_s
  end
end
