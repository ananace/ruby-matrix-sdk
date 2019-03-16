require 'test_helper'

class ApiTest < Test::Unit::TestCase
  def setup
    @http = mock()
    @http.stubs(:active?).returns(true)

    @api = MatrixSdk::Api.new 'https://example.com', protocols: :CS
    @api.instance_variable_set :@http, @http
    @api.stubs(:print_http)
  end

  def mock_success(body)
    response = mock()
    response.stubs(:is_a?).with(Net::HTTPTooManyRequests).returns(false)
    response.stubs(:is_a?).with(Net::HTTPSuccess).returns(true)
    response.stubs(:body).returns(body)
    response
  end

  def test_whoami
    @http.expects(:request).returns(mock_success('{"user_id":"@user:example.com"}'))
    assert_equal @api.whoami?, { user_id: '@user:example.com' }
  end

  def test_sync
    @http.expects(:request).with do |req|
      req.path == '/_matrix/client/r0/sync?timeout=30000'
    end.returns(mock_success('{}'))
    assert_not_nil @api.sync.nil?
  end

  def test_send_message
    @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/send/m.room.message/42', body: { msgtype: 'm.text', body: 'this is a message' }, query: {}).returns({})
    assert_not_nil @api.send_message('!room:example.com', 'this is a message', txn_id: 42)
  end

  def test_send_emote
    @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/send/m.room.message/42', body: { msgtype: 'm.emote', body: 'this is an emote' }, query: {}).returns({})
    assert_not_nil @api.send_emote('!room:example.com', 'this is an emote', txn_id: 42)
  end

  def test_redact_event
    @api.expects(:request).with(:put, :client_r0, '/rooms/%21room%3Aexample.com/redact/%24eventid%3Aexample.com/42', body: {}, query: {}).returns({})
    assert_not_nil @api.redact_event('!room:example.com', '$eventid:example.com', txn_id: 42)
  end
end
