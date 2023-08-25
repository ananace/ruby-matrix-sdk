require 'simplecov'
SimpleCov.start do
  add_filter '/test/'
  add_filter '/vendor/'
end

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'matrix_sdk'

require 'test/unit'
require 'mocha/test_unit'
require 'webmock/test_unit'

RUBY_MAJOR_MINOR_VERSION = RUBY_VERSION[0..2].freeze
OLDER_RUBY = %w[2.5 2.6].include?(RUBY_MAJOR_MINOR_VERSION)

def expect_message(object, message, *args)
  args = args << {} if OLDER_RUBY
  object.expects(message).with(*args)
end

class Test::Unit::TestCase
  def matrixsdk_add_api_stub
    MatrixSdk::Api
      .any_instance
      .stubs(:client_api_latest)
      .returns(:client_r0)
  end
end
