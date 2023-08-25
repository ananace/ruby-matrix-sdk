# frozen_string_literal: true

module MatrixSdk::Bot
  PARAMS_CONFIG = {} # rubocop:disable Style/MutableConstant Intended

  PARAMS_CONFIG[:homeserver] = ENV['MATRIX_HS'] if ENV.key? 'MATRIX_HS'
  PARAMS_CONFIG[:access_token] = ENV['MATRIX_TOKEN'] if ENV.key? 'MATRIX_TOKEN'
  PARAMS_CONFIG[:username] = ENV['MATRIX_USERNAME'] if ENV.key? 'MATRIX_USERNAME'
  PARAMS_CONFIG[:password] = ENV['MATRIX_PASSWORD'] if ENV.key? 'MATRIX_PASSWORD'

  require 'optparse'
  parser = OptionParser.new do |op|
    op.on('-s homeserver', 'Specify homeserver') { |val| PARAMS_CONFIG[:homeserver] = val }

    op.on('-T token', 'Token') { |val| PARAMS_CONFIG[:access_token] = val }
    op.on('-U username', 'Username') { |val| PARAMS_CONFIG[:username] = val }
    op.on('-P password', 'Password') { |val| PARAMS_CONFIG[:password] = val }

    op.on('-q', 'Disable logging') { PARAMS_CONFIG[:logging] = false }
    op.on('-v', 'Enable verbose output') { PARAMS_CONFIG[:logging] = !(PARAMS_CONFIG[:log_level] = :debug).nil? }
  end

  begin
    parser.parse!(ARGV.dup)
  rescue StandardError => e
    PARAMS_CONFIG[:optparse_error] = e
  end

  MatrixSdk.logger.appenders.each do |log|
    log.layout = Logging::Layouts.pattern(
      pattern: "%d|%.1l %c : %m\n"
    )
  end
  MatrixSdk.debug! if ENV['MATRIX_DEBUG'] == '1'

  require 'matrix_sdk/bot/base'
  class Instance < Base
    set :logging, true
    set :log_level, :info

    set :app_file, caller_files.first || $PROGRAM_NAME
    set(:run) { File.expand_path($PROGRAM_NAME) == File.expand_path(app_file) }

    if run? && ARGV.any?
      error = PARAMS_CONFIG.delete(:optparse_error)
      raise error if error

      PARAMS_CONFIG.each { |k, v| set k, v }
    end
  end

  module Delegator
    def self.delegate(*methods)
      methods.each do |method_name|
        define_method(method_name) do |*args, &block|
          return super(*args, &block) if respond_to? method_name

          Delegator.target.send(method_name, *args, &block)
        end
        # ensure keyword argument passing is compatible with ruby >= 2.7
        ruby2_keywords(method_name) if respond_to?(:ruby2_keywords, true)
        private method_name
      end
    end

    delegate :command, :client, :event,
             :settings,
             :set, :enable, :disable

    class << self
      attr_accessor :target
    end

    self.target = Instance
  end

  # Trigger the global instance to run once the main class finishes
  at_exit do
    remove_const(:PARAMS_CONFIG)
    Instance.run! if $!.nil? && Instance.run? # rubocop:disable Style/SpecialGlobalVars Don't want to require into global scope
  end
end

extend MatrixSdk::Bot::Delegator # rubocop:disable Style/MixinUsage Intended
