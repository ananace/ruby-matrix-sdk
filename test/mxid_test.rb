require 'test_helper'

class MXIDTest < Test::Unit::TestCase
  def test_creation
    user = MatrixSdk::MXID.new '@user:example.com'
    room_id = MatrixSdk::MXID.new '!opaque:example.com'
    event = MatrixSdk::MXID.new '$opaque:example.com'
    event3 = MatrixSdk::MXID.new '$0paqu3+strin6+w1th+special/chars'
    group = MatrixSdk::MXID.new '+group:example.com'
    room_alias = MatrixSdk::MXID.new '#alias:example.com'

    assert user.valid?
    assert room_id.valid?
    assert event.valid?
    assert event3.valid?
    assert group.valid?
    assert room_alias.valid?

    assert user.user?
    assert room_id.room?
    assert room_id.room_id?
    assert !room_id.room_alias?
    assert event.event?
    assert event3.event?
    assert group.group?
    assert room_alias.room?
    assert !room_alias.room_id?
    assert room_alias.room_alias?
  end

  def test_to_s
    input = %w[@user:example.com !opaque:example.com $opaque:example.com $0paqu3+strin6+w1th+special/chars +group:example.com #alias:example.com]
    input.each do |mxid|
      parsed = MatrixSdk::MXID.new mxid

      assert_equal mxid, parsed.to_s
      assert mxid == parsed
      assert parsed == mxid
    end
  end

  def test_parse
    input = %w[@user:example.com !opaque:example.com $opaque:example.com +group:example.com #alias:example.com]

    input.each do |mxid|
      parsed = MatrixSdk::MXID.new mxid

      assert_equal 'example.com', parsed.domain
    end

    assert_nil MatrixSdk::MXID.new('$0paqu3+strin6+w1th+special/chars').domain
    assert_nil MatrixSdk::MXID.new('@user:example.com').port
    parsed = MatrixSdk::MXID.new '#room:matrix.example.com:8448'

    assert_equal '#', parsed.sigil
    assert_equal 'room', parsed.localpart
    assert_equal 'matrix.example.com', parsed.domain
    assert_equal 8448, parsed.port

    assert_equal '#room:matrix.example.com:8448', parsed.to_s
  end

  def test_parse_failures
    assert_raises(ArgumentError) { MatrixSdk::MXID.new nil }
    assert_raises(ArgumentError) { MatrixSdk::MXID.new true }
    assert_raises(ArgumentError) { MatrixSdk::MXID.new '#asdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfadsfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfadsfasdfadsfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdfasdf:example.com' }
    assert_raises(ArgumentError) { MatrixSdk::MXID.new '' }
    assert_raises(ArgumentError) { MatrixSdk::MXID.new 'user:example.com' }
    assert_raises(ArgumentError) { MatrixSdk::MXID.new '@user' }
  end
end
