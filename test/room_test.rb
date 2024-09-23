require 'test_helper'

class RoomTest < Test::Unit::TestCase
  def setup
    super

    # Silence debugging output
    ::MatrixSdk.logger.level = :error

    @api = MatrixSdk::Api.new 'https://example.com', protocols: :CS

    @client = MatrixSdk::Client.new @api
    @client.stubs(:mxid).returns('@alice:example.com')

    @id = '!room:example.com'
    @client.send :ensure_room, @id
    @room = @client.rooms.first
  end

  def test_pre_joined_members
    users = [MatrixSdk::User.new(@client, '@alice:example.com', display_name: 'Alice')]
    users.each do |u|
      @room.send :ensure_member, u
    end

    @api.expects(:get_room_members).never
    @api.expects(:get_room_joined_members).never

    assert_equal users, @room.joined_members
  end

  def test_joined_members
    assert_equal :all, @room.client.cache

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/joined_members').to_return_json(
      body: {
        joined: {
          '@alice:example.com': { display_name: 'Alice' },
          '@charlie:example.com': { display_name: 'Charlie' }
        }
      }
    )

    assert_equal 2, @room.joined_members.count
    assert_equal '@alice:example.com', @room.joined_members.first.id
    assert_equal '@charlie:example.com', @room.joined_members.last.id
    assert @room.dm?(members_only: true)
  end

  def test_dm
    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/joined_members').to_return_json(
      body: {
        joined: {
          '@alice:example.com': {},
          '@bob:example.com': {},
          '@charlie:example.com': {}
        }
      }
    )

    refute @room.dm?(members_only: true)

    stub_request(:get, 'https://example.com/_matrix/client/v3/user/@alice:example.com/account_data/m.direct').to_return_json(
      body: {
        '@bob:example.com' => [@id]
      }
    )

    assert @room.dm?
  end

  def test_all_members
    assert_equal :all, @room.client.cache

    @client.expects(:get_user).twice.with('@alice:example.com').returns(MatrixSdk::User.new(@client, '@alice:example.com'))
    @client.expects(:get_user).once.with('@charlie:example.com').returns(MatrixSdk::User.new(@client, '@charlie:example.com'))

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/members').to_return_json(
      body: {
        chunk: [
          { state_key: '@alice:example.com' }
        ]
      }
    )

    # Two calls, cache should be kept
    assert_equal 1, @room.all_members.count
    assert_equal '@alice:example.com', @room.all_members.first.id

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/members?filter=something').to_return_json(
      body: {
        chunk: [
          { state_key: '@alice:example.com' },
          { state_key: '@charlie:example.com' }
        ]
      }
    )

    # Filter, should skip cache and return another value
    members = @room.all_members(filter: 'something')
    assert_equal 2, members.count
    assert_equal '@alice:example.com', members.first.id
    assert_equal '@charlie:example.com', members.last.id

    # No filter, should return to cached data
    assert_equal 1, @room.all_members.count
    assert_equal '@alice:example.com', @room.all_members.first.id
  end

  def test_wrapped_methods
    text = '<b>test</b>'
    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.text', body: text }).to_return_json(body: {})
    @room.send_text(text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.text', body: 'test', formatted_body: text, format: 'org.matrix.custom.html' }).to_return_json(body: {})
    @room.send_html(text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.emote', body: text }).to_return_json(body: {})
    @room.send_emote(text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.file', body: text, url: 'mxc://example.com/file', info: {} }).to_return_json(body: {})
    @room.send_file('mxc://example.com/file', text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.notice', body: text }).to_return_json(body: {})
    @room.send_notice(text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.image', body: text, url: 'mxc://example.com/file', info: {} }).to_return_json(body: {})
    @room.send_image('mxc://example.com/file', text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.location', body: text, geo_uri: 'geo:1,2,3', info: { thumbnail_url: nil, thumbnail_info: {} } }).to_return_json(body: {})
    @room.send_location('geo:1,2,3', text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.video', body: text, url: 'mxc://example.com/file', info: {} }).to_return_json(body: {})
    @room.send_video('mxc://example.com/file', text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/send/m.room.message/\d+}).with(body: { msgtype: 'm.audio', body: text, url: 'mxc://example.com/file', info: {} }).to_return_json(body: {})
    @room.send_audio('mxc://example.com/file', text)

    stub_request(:put, %r{https://example.com/_matrix/client/v3/rooms/!room:example.com/redact/\$event:example.com/\d+}).with(body: { reason: text }).to_return_json(body: {})
    @room.redact_message('$event:example.com', text)

    stub_request(:post, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/invite').with(body: { user_id: '@bob:example.com' }).to_return_json(body: {})
    @room.invite_user('@bob:example.com')

    stub_request(:post, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/kick').with(body: { user_id: '@bob:example.com', reason: text }).to_return_json(body: {})
    @room.kick_user('@bob:example.com', text)

    stub_request(:post, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/ban').with(body: { user_id: '@bob:example.com', reason: text }).to_return_json(body: {})
    @room.ban_user('@bob:example.com', text)

    stub_request(:post, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/unban').with(body: { user_id: '@bob:example.com' }).to_return_json(body: {})
    @room.unban_user('@bob:example.com')

    stub_request(:post, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/leave').to_return_json(body: {})
    @client.instance_variable_get(:@rooms).expects(:delete).with(@id)
    @room.leave

    stub_request(:get, 'https://example.com/_matrix/client/v3/user/@alice:example.com/rooms/!room:example.com/account_data/com.example.Test').to_return_json(body: {})
    @room.get_account_data('com.example.Test')

    stub_request(:put, 'https://example.com/_matrix/client/v3/user/@alice:example.com/rooms/!room:example.com/account_data/com.example.Test').with(body: { data: true }).to_return_json(body: {})
    @room.set_account_data('com.example.Test', data: true)

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.member/@alice:example.com').to_return_json(body: { membership: 'join' })
    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.member/@alice:example.com').with(body: { membership: 'join', displayname: 'Alice', avatar_url: 'mxc://example.com/avatar', reason: 'Updating room profile information' }).to_return_json(body: {})
    @room.set_user_profile display_name: 'Alice', avatar_url: 'mxc://example.com/avatar'

    stub_request(:get, 'https://example.com/_matrix/client/v3/user/@alice:example.com/rooms/!room:example.com/tags').to_return_json(body: { tags: { 'example.tag': {} }})
    tags = @room.tags

    stub_request(:put, 'https://example.com/_matrix/client/v3/user/@alice:example.com/rooms/!room:example.com/tags/test.tag').with(body: { }).to_return_json(body: {})
    tags.add 'test.tag', data: true

    stub_request(:delete, 'https://example.com/_matrix/client/v3/user/@alice:example.com/rooms/!room:example.com/tags/test.tag').to_return_json(body: {})
    tags.remove 'test.tag'

    assert_nil tags[:'test.tag']
    assert_not_nil tags[:'example.tag']

    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.name').with(body: { name: 'name' }).to_return_json(body: {})
    @room.name = 'name'

    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.topic').with(body: { topic: 'topic' }).to_return_json(body: {})
    @room.topic = 'topic'

    stub_request(:put, 'https://example.com/_matrix/client/v3/directory/room/%23room:example.com').with(body: { room_id: '!room:example.com' }).to_return_json(body: {})
    @room.add_alias('#room:example.com')

    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.join_rules').with(body: { join_rule: 'invite' }).to_return_json(body: {}).times(2)
    @room.invite_only = true
    @room.join_rule = :invite

    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.join_rules').with(body: { join_rule: 'public' }).to_return_json(body: {}).times(2)
    @room.invite_only = false
    @room.join_rule = :public

    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.guest_access').with(body: { guest_access: 'can_join' }).to_return_json(body: {}).times(2)
    @room.allow_guests = true
    @room.guest_access = :can_join

    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.guest_access').with(body: { guest_access: 'forbidden' }).to_return_json(body: {}).times(2)
    @room.allow_guests = false
    @room.guest_access = :forbidden

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.power_levels').to_return_json(body: {
      users: { '@alice:example.com': 100, '@bob:example.com': 50 },
      users_default: 0
    })
    @room.power_levels

    assert_true @room.admin? '@alice:example.com'
    assert_true @room.moderator? '@alice:example.com'
    assert_true @room.moderator? '@bob:example.com'
    assert_false @room.moderator? '@charlie:example.com'

    assert @room.user_can_send? '@alice:example.com', 'm.room.message'
    assert @room.user_can_send? '@alice:example.com', 'm.room.name', state: true
    refute @room.user_can_send? '@charlie:example.com', 'm.room.topic', state: true

    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.power_levels').with(body: {
      users: { '@alice:example.com': 100, '@bob:example.com': 50, '@charlie:example.com': 50 },
      users_default: 0
    }).to_return_json(body: {}).times(2)
    @room.moderator! '@charlie:example.com'

    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.power_levels').with(body: {
      users: { '@alice:example.com': 100, '@bob:example.com': 50, '@charlie:example.com': 100 },
      users_default: 0
    }).to_return_json(body: {}).times(2)
    @room.admin! '@charlie:example.com'
  end

  def test_state_refresh
    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.name').to_return_json(body: { name: 'New name' })
    @room.reload_name!

    assert_equal 'New name', @room.name

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.topic').to_return_json(body: { topic: 'New topic' })
    @room.reload_topic!

    assert_equal 'New topic', @room.topic

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.canonical_alias').to_return_json(body: { alias: '#test:example.com' }).times(1)
    assert @room.aliases.include? '#test:example.com'
    assert @room.aliases.include? '#test:example.com'

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.canonical_alias').to_return_json(body: { alias: '#test:example.com', alt_aliases: ['#test:example1.com'] }).times(1)
    @room.reload_aliases!
    assert @room.aliases.include? '#test:example.com'
    assert @room.aliases.include? '#test:example1.com'

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.canonical_alias').to_return_json(body: { alias: '#test:example.com', alt_aliases: ['#test:example2.com'] }).times(1)
    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/aliases').to_return_json(body: { aliases: ['#test:example1.com'] })
    @room.reload_aliases!
    aliases = @room.aliases(canonical_only: false)
    assert aliases.include? '#test:example.com'
    assert aliases.include? '#test:example1.com'
    assert aliases.include? '#test:example2.com'

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.canonical_alias').to_return_json(status: 404, body: {})
    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/aliases').to_return_json(body: { aliases: ['#test:example.com'] })
    @room.reload_aliases!
    assert @room.aliases(canonical_only: false).include? '#test:example.com'

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.canonical_alias').to_return_json(status: 404, body: {})
    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/aliases').to_return_json(body: { aliases: ['#test2:example.com'] })
    @room.reload_aliases!
    assert @room.aliases(canonical_only: false).include?('#test2:example.com')

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.canonical_alias').to_return_json(status: 404, body: {})
    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/aliases').to_return_json(body: { aliases: ['#test2:example.com'] })
    @room.reload_aliases!
    assert !@room.aliases(canonical_only: false).include?('#test:example.com')
  end

  def test_modifies
    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.power_levels').to_return_json(
      body: {
        users_default: 0,
        redact: 50
      }
    )
    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.power_levels').with(
      body: {
        users_default: 5,
        redact: 50,
        users: {
          '@alice:example.com': 100
        }
      }
    ).to_return_json(
      body: {}
    )
    @room.modify_user_power_levels({ '@alice:example.com': 100 }, 5)

    stub_request(:get, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.power_levels').to_return_json(
      body: {
        users_default: 10,
      }
    )
    stub_request(:put, 'https://example.com/_matrix/client/v3/rooms/!room:example.com/state/m.room.power_levels').with(
      body: {
        users_default: 10,
        events: {
          'm.room.message': 100
        }
      }
    ).to_return_json(
      body: {}
    )
    @room.modify_required_power_levels 'm.room.message': 100
  end
end
