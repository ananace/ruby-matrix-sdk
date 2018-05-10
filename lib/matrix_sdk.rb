require 'matrix_sdk/extensions'
require 'matrix_sdk/version'

module MatrixSdk
  autoload :Api, 'matrix_sdk/api'
  autoload :Client, 'matrix_sdk/client'
  autoload :Room, 'matrix_sdk/room'
  autoload :User, 'matrix_sdk/user'

  autoload :MatrixError, 'matrix_sdk/errors'
  autoload :MatrixRequestError, 'matrix_sdk/errors'
  autoload :MatrixConnectionError, 'matrix_sdk/errors'
end
