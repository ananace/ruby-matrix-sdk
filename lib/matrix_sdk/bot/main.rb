# frozen_string_literal: true

module MatrixSdk::Bot
  PARAMS_CONFIG = {} # rubocop:disable Style/MutableConstant Intended

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

  require 'matrix_sdk/bot/base'

  class Instance < Base
    set :app_file, caller_files.first || $PROGRAM_NAME
    set(:run) { File.expand_path($PROGRAM_NAME) == File.expand_path(app_file) }

    if run? && ARGV.any?
      error = PARAMS_CONFIG.delete(:optparse_error)
      raise error if error

      PARAMS_CONFIG.each { |k, v| set k, v }
    end
  end

  remove_const(:PARAMS_CONFIG)
  at_exit { Instance.run! if $!.nil? && Instance.run? } # rubocop:disable Style/SpecialGlobalVars Don't require into global scope

  MatrixSdk.logger
  MatrixSdk.debug! if ENV['MATRIX_DEBUG'] == '1'
end

extend MatrixSdk::Bot::Delegator # rubocop:disable Style/MixinUsage Intended
