require 'test_helper'

class MatrixSdkTest < Test::Unit::TestCase
  def test_that_it_has_a_version_number
    refute_nil ::MatrixSdk::VERSION
  end

  def test_debugging
    ::MatrixSdk.debug!

    assert_equal 0, ::MatrixSdk.logger.level
  end
end
