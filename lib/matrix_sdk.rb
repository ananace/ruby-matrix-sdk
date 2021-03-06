# frozen_string_literal: true

require 'json'
require 'logging'
require 'zeitwerk'

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect(
  'as' => 'AS',
  'cs' => 'CS',
  'is' => 'IS',
  'msc' => 'MSC',
  'mxid' => 'MXID',
  'ss' => 'SS'
)
loader.collapse("#{__dir__}/matrix_sdk/errors")
loader.setup

module MatrixSdk
  def self.debug!
    logger.level = :debug
  end

  def self.logger
    @logger ||= ::Logging.logger[self].tap do |logger|
      logger.add_appenders ::Logging.appenders.stdout
      logger.level = :info
    end
  end

  def self.logger=(global_logger)
    @logger = global_logger
    @global_logger = !global_logger.nil?
  end

  def self.global_logger?
    @global_logger ||= false
  end
end
