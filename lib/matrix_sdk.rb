require 'matrix_sdk/extensions'
require 'matrix_sdk/version'

require 'json'

autoload :Logging, 'logging'

module MatrixSdk
  autoload :Api, 'matrix_sdk/api'
  autoload :ApplicationService, 'matrix_sdk/application_service'
  autoload :Client, 'matrix_sdk/client'
  autoload :MXID, 'matrix_sdk/mxid'
  autoload :Response, 'matrix_sdk/response'
  autoload :Room, 'matrix_sdk/room'
  autoload :User, 'matrix_sdk/user'

  autoload :MatrixError, 'matrix_sdk/errors'
  autoload :MatrixRequestError, 'matrix_sdk/errors'
  autoload :MatrixConnectionError, 'matrix_sdk/errors'
  autoload :MatrixUnexpectedResponseError, 'matrix_sdk/errors'

  module Protocols
    autoload :AS, 'matrix_sdk/protocols/as'
    autoload :CS, 'matrix_sdk/protocols/cs'
    autoload :IS, 'matrix_sdk/protocols/is'
    autoload :SS, 'matrix_sdk/protocols/ss'
  end

  def self.debug!
    logger.level = :debug
  end

  def self.logger
    @logger ||= Logging.logger[self].tap do |logger|
      logger.add_appenders Logging.appenders.stdout
      logger.level = :info
    end
  end
end
