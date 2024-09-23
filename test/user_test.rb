require 'test_helper'

class UserTest < Test::Unit::TestCase
  def setup
    super

    @api = MatrixSdk::Api.new 'https://example.com', protocols: :CS

    @client = MatrixSdk::Client.new @api
    @client.stubs(:mxid).returns('@alice:example.com')

    @id = '@alice:example.com'
    @user = @client.get_user @id
  end

  def test_wrappers
    stub_request(:get, 'https://example.com/_matrix/client/v3/profile/@alice:example.com/displayname').to_return_json(body: { displayname: nil })
    assert_equal @id, @user.friendly_name

    stub_request(:get, 'https://example.com/_matrix/client/v3/profile/@alice:example.com/displayname').to_return_json(body: { displayname: 'Alice' })
    assert_equal 'Alice', @user.display_name
    assert_equal 'Alice', @user.friendly_name

    stub_request(:put, 'https://example.com/_matrix/client/v3/profile/@alice:example.com/displayname').with(body: { displayname: 'Alice' }).to_return_json(body: {})
    @user.display_name = 'Alice'

    stub_request(:get, 'https://example.com/_matrix/client/v3/profile/@alice:example.com/avatar_url').to_return_json(body: { avatar_url: 'mxc://example.com/avatar' })
    assert_equal 'mxc://example.com/avatar', @user.avatar_url

    stub_request(:put, 'https://example.com/_matrix/client/v3/profile/@alice:example.com/avatar_url').with(body: { avatar_url: 'mxc://example.com/avatar' }).to_return_json(body: {})
    @user.avatar_url = 'mxc://example.com/avatar'

    data = { device_keys: { @id.to_sym => ['Keys here'] } }
    stub_request(:post, 'https://example.com/_matrix/client/v3/keys/query').with(body: hash_including(device_keys: { '@alice:example.com': [] })).to_return_json(body: data)
    assert_equal ['Keys here'], @user.device_keys

    data = {
      presence: 'online',
      last_active_ago: 5000,
      currently_active: true,
      status_msg: 'Testing'
    }
    stub_request(:get, 'https://example.com/_matrix/client/v3/presence/@alice:example.com/status').to_return_json(body: data)

    assert @user.active?
    assert_equal :online, @user.presence
    assert_equal 'Testing', @user.status_msg
    assert_equal (Time.now - 5).to_i, @user.last_active.to_i
  end
end
