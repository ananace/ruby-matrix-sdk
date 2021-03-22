# frozen_string_literal: true

require 'test_helper'

class TinycacheCustomTest < Test::Unit::TestCase
  class CustomAdapter
    def fetch(key, **_); end
  end

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

  def test_custom_adapter
    MatrixSdk::Util::Tinycache.adapter = CustomAdapter
    test = TestClass.new

    CustomAdapter.any_instance.expects(:fetch).returns('data')

    assert test.tinycache_adapter
    assert 'data', test.permanent
  end
end
