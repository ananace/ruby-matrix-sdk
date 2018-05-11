module MatrixSdk
  # A generic error raised for issues in the MatrixSdk
  class MatrixError < StandardError
  end

  # An error specialized and raised for failed requests
  class MatrixRequestError < MatrixError
    attr_reader :code, :httpstatus, :message
    alias error message

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

  # An error raised when errors occur in the connection layer
  class MatrixConnectionError < MatrixError
  end

  # An error raised when the homeserver returns an unexpected response to the client
  class MatrixUnexpectedResponseError < MatrixError
  end
end
