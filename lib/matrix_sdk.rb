require 'matrix_sdk/extensions'
require 'matrix_sdk/version'

autoload :Logging, 'logging'

module MatrixSdk
  autoload :Api, 'matrix_sdk/api'
  autoload :Client, 'matrix_sdk/client'
  autoload :Response, 'matrix_sdk/response'
  autoload :Room, 'matrix_sdk/room'
  autoload :User, 'matrix_sdk/user'

  autoload :MatrixError, 'matrix_sdk/errors'
  autoload :MatrixRequestError, 'matrix_sdk/errors'
  autoload :MatrixConnectionError, 'matrix_sdk/errors'
  autoload :MatrixUnexpectedResponseError, 'matrix_sdk/errors'

  def self.debug!
    logger.level = :debug
  end

  def self.logger
    @logger ||= Logging.logger[name].tap do |logger|
      logger.add_appenders Logging.appenders.stdout
      logger.level = :warn
    end
  end
end
