# frozen_string_literal: true

require 'matrix_sdk/util/extensions'
require 'matrix_sdk/util/uri'
require 'matrix_sdk/version'

require 'json'

autoload :Logging, 'logging'

module MatrixSdk
  autoload :Api, 'matrix_sdk/api'
  # autoload :ApplicationService, 'matrix_sdk/application_service'
  autoload :Client, 'matrix_sdk/client'
  autoload :MXID, 'matrix_sdk/mxid'
  autoload :Response, 'matrix_sdk/response'
  autoload :Room, 'matrix_sdk/room'
  autoload :User, 'matrix_sdk/user'

  autoload :MatrixError, 'matrix_sdk/errors'
  autoload :MatrixRequestError, 'matrix_sdk/errors'
  autoload :MatrixNotAuthorizedError, 'matrix_sdk/errors'
  autoload :MatrixForbiddenError, 'matrix_sdk/errors'
  autoload :MatrixNotFoundError, 'matrix_sdk/errors'
  autoload :MatrixConflictError, 'matrix_sdk/errors'
  autoload :MatrixTooManyRequestsError, 'matrix_sdk/errors'
  autoload :MatrixConnectionError, 'matrix_sdk/errors'
  autoload :MatrixTimeoutError, 'matrix_sdk/errors'
  autoload :MatrixUnexpectedResponseError, 'matrix_sdk/errors'

  module Bot
    autoload :Base, 'matrix_sdk/bot/base'
    autoload :Request, 'matrix_sdk/bot/request'
  end

  module Rooms
    autoload :Space, 'matrix_sdk/rooms/space'
  end

  module Util
    autoload :Tinycache, 'matrix_sdk/util/tinycache'
    autoload :TinycacheAdapter, 'matrix_sdk/util/tinycache_adapter'
  end

  module Protocols
    autoload :AS, 'matrix_sdk/protocols/as'
    autoload :CS, 'matrix_sdk/protocols/cs'
    autoload :IS, 'matrix_sdk/protocols/is'
    autoload :SS, 'matrix_sdk/protocols/ss'

    # Non-final protocol extensions
    autoload :MSC, 'matrix_sdk/protocols/msc'
  end

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
