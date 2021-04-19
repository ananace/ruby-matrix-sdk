# frozen_string_literal: true

require 'test_helper'

class URITest < Test::Unit::TestCase
  def test_creation
    uri = URI('matrix:u/her:example.org')

    assert_equal MatrixSdk::MXID.new('@her:example.org'), uri.mxid

    uri = URI('matrix:u/her:example.org?action=chat')

    assert_equal MatrixSdk::MXID.new('@her:example.org'), uri.mxid
    assert_equal 'action=chat', uri.query
    assert_equal :chat, uri.action

    uri = URI('matrix:roomid/rid:example.org')

    assert_equal MatrixSdk::MXID.new('!rid:example.org'), uri.mxid

    uri = URI('matrix:r/us:example.org')

    assert_equal MatrixSdk::MXID.new('#us:example.org'), uri.mxid

    uri = URI('matrix:roomid/rid:example.org?action=join&via=example2.org')

    assert_equal MatrixSdk::MXID.new('!rid:example.org'), uri.mxid
    assert_equal 'action=join&via=example2.org', uri.query
    assert_equal :join, uri.action
    assert_equal ['example2.org'], uri.via

    uri = URI('matrix:r/us:example.org?action=join')

    assert_equal MatrixSdk::MXID.new('#us:example.org'), uri.mxid
    assert_equal 'action=join', uri.query
    assert_equal :join, uri.action

    uri = URI('matrix:r/us:example.org/e/lol823y4bcp3qo4')

    assert_equal MatrixSdk::MXID.new('#us:example.org'), uri.mxid
    assert uri.mxid2?
    assert_equal MatrixSdk::MXID.new('$lol823y4bcp3qo4'), uri.mxid2

    uri = URI('matrix:roomid/rid:example.org/event/lol823y4bcp3qo4?via=example2.org')

    assert_equal MatrixSdk::MXID.new('!rid:example.org'), uri.mxid
    assert uri.mxid2?
    assert_equal MatrixSdk::MXID.new('$lol823y4bcp3qo4'), uri.mxid2
    assert_equal ['example2.org'], uri.via

    mxid = MatrixSdk::MXID.new('!rid:example.org')

    assert_equal URI('matrix:roomid/rid:example.org'), mxid.to_uri

    mxid = MatrixSdk::MXID.new('!rid:example.org')

    assert_equal URI('matrix:roomid/rid:example.org?action=join&via=example.org'), mxid.to_uri(action: :join, via: 'example.org')

    mxid = MatrixSdk::MXID.new('#us:example.org')

    assert_equal URI('matrix:r/us:example.org?via=example.org&via=example2.org'), mxid.to_uri(via: ['example.org', 'example2.org'])

    mxid = MatrixSdk::MXID.new('!rid:example.org')

    assert_equal URI('matrix:roomid/rid:example.org/e/lol823y4bcp3qo4?via=example2.org'), mxid.to_uri(event_id: '$lol823y4bcp3qo4', via: 'example2.org')

    mxid = MatrixSdk::MXID.new('!rid:example.org')

    assert_equal URI('matrix:roomid/rid:example.org/e/lol823y4bcp3qo4?via=example2.org'), mxid.to_uri(event_id: MatrixSdk::MXID.new('$lol823y4bcp3qo4'), via: 'example2.org')
  end

  def test_undefined_handling
    uri = URI('matrix:/roomid/rid:example.org?action=join&via=example2.org#fragment')

    assert_equal MatrixSdk::MXID.new('!rid:example.org'), uri.mxid
    assert_equal ['example2.org'], uri.via
    assert_equal 'fragment', uri.fragment

    uri = URI('matrix://authority/roomid/rid:example.org?action=join&via=example2.org')

    assert_equal MatrixSdk::MXID.new('!rid:example.org'), uri.mxid
    assert_equal ['example2.org'], uri.via
    assert_equal 'authority', uri.authority

    uri = URI('matrix://authority/roomid/rid:example.org?action=join&via=example2.org#fragment')

    assert_equal MatrixSdk::MXID.new('!rid:example.org'), uri.mxid
    assert_equal ['example2.org'], uri.via
    assert_equal 'authority', uri.authority
    assert_equal 'fragment', uri.fragment
  end

  def test_creation_failure
    assert_raises(URI::InvalidComponentError) { URI('matrix:r/rid:example.org/') }
    assert_raises(URI::InvalidComponentError) { URI('matrix:something/blah') }
    assert_raises(URI::InvalidComponentError) { URI('matrix:r/') }
    assert_raises(URI::InvalidComponentError) { URI('matrix:r/room:example.com//') }
    assert_raises(URI::InvalidComponentError) { URI('matrix:r/room:example.com/blah') }
    assert_raises(URI::InvalidComponentError) { URI('matrix:r/room:example.com/e/') }
  end
end
