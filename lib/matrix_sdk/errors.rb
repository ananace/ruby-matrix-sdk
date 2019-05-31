# frozen_string_literal: true

module MatrixSdk
  # A generic error raised for issues in the MatrixSdk
  class MatrixError < StandardError
  end

  # An error specialized and raised for failed requests
  class MatrixRequestError < MatrixError
    attr_reader :code, :httpstatus, :message
    alias error message

    def self.class_by_code(code)
      return MatrixNotFoundError if code == 404

      MatrixRequestError
    end

    def self.new_by_code(data, code)
      class_by_code(code).new(data, code)
    end

    def initialize(error, status)
      @code = error[:errcode]
      @httpstatus = status
      @message = error[:error]

      super error[:error]
    end

    def to_s
      "HTTP #{httpstatus} (#{code}): #{message}"
    end
  end

  class MatrixNotFoundError < MatrixError; end

  # An error raised when errors occur in the connection layer
  class MatrixConnectionError < MatrixError
    def self.class_by_code(code)
      return MatrixTimeoutError if code == 504

      MatrixConnectionError
    end
  end

  class MatrixTimeoutError < MatrixConnectionError
  end

  # An error raised when the homeserver returns an unexpected response to the client
  class MatrixUnexpectedResponseError < MatrixError
  end
end
