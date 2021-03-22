# frozen_string_literal: true

require 'test_helper'

class TinycacheTest < Test::Unit::TestCase
  class TestClass
    extend MatrixSdk::Util::Tinycache

    attr_accessor :client

    cached :permanent
    cached :temporary, expires_in: 1
    cached :very_temporary, expires_in: 0.1

    cached :level_all, cache_level: :all
    cached :level_some, cache_level: :some
    cached :level_none, cache_level: :none

    def test_point(source)
      source
    end

    %i[permanent temporary very_temporary level_all level_some level_none].each do |method|
      define_method(method) do
        test_point(method)
      end
    end
  end

  def setup
    @client = mock
    @client.stubs(:cache).returns(nil)
    @cached = TestClass.new
    @cached.stubs(:client).returns(@client)
    MatrixSdk::Util::Tinycache.adapter = MatrixSdk::Util::TinycacheAdapter

    assert @cached.tinycache_adapter
    assert @cached.permanent_cached?
    assert @cached.temporary_cached?
    assert @cached.very_temporary_cached?
  end

  def test_cache
    @cached.expects(:test_point).with(:permanent).once.returns(:permanent)
    @cached.expects(:test_point).with(:temporary).once.returns(:temporary)
    @cached.expects(:test_point).with(:very_temporary).once.returns(:very_temporary)

    5.times { assert_equal :permanent, @cached.permanent }
    5.times { assert_equal :temporary, @cached.temporary }
    5.times { assert_equal :very_temporary, @cached.very_temporary }
  end

  def test_expiry
    @cached.expects(:test_point).with(:very_temporary).twice.returns(:very_temporary)
    @cached.very_temporary

    sleep 0.15
    5.times { assert_equal :very_temporary, @cached.very_temporary }
  end

  def test_cache_level
    @client.stubs(:cache).returns(:all)
    @cached.expects(:test_point).with(:level_all).once.returns(:level_all)
    @cached.expects(:test_point).with(:level_some).once.returns(:level_some)
    @cached.expects(:test_point).with(:level_none).once.returns(:level_none)

    5.times { assert_equal :level_all, @cached.level_all }
    5.times { assert_equal :level_some, @cached.level_some }
    5.times { assert_equal :level_none, @cached.level_none }

    @client.stubs(:cache).returns(:some)
    @cached.tinycache_adapter.clear
    @cached.expects(:test_point).with(:level_all).times(5).returns(:level_all)
    @cached.expects(:test_point).with(:level_some).once.returns(:level_some)
    @cached.expects(:test_point).with(:level_none).once.returns(:level_none)

    5.times { assert_equal :level_all, @cached.level_all }
    5.times { assert_equal :level_some, @cached.level_some }
    5.times { assert_equal :level_none, @cached.level_none }

    @client.stubs(:cache).returns(:none)
    @cached.tinycache_adapter.clear
    @cached.expects(:test_point).with(:level_all).times(5).returns(:level_all)
    @cached.expects(:test_point).with(:level_some).times(5).returns(:level_some)
    @cached.expects(:test_point).with(:level_none).once.returns(:level_none)

    5.times { assert_equal :level_all, @cached.level_all }
    5.times { assert_equal :level_some, @cached.level_some }
    5.times { assert_equal :level_none, @cached.level_none }
  end
end
