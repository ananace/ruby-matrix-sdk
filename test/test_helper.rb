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
  def stub_api_version_request
    body = JSON.parse(File.read(File.join(__dir__, 'fixtures/versions_response.json')))

    stub_request(:get, %r{https://.+/_matrix/client/versions}).to_return_json(body:)
  end

  def setup
    stub_api_version_request
  end
end
