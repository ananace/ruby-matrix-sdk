module MatrixSdk
  class MatrixError < StandardError
  end

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

  class MatrixConnectionError < MatrixError
  end

  class MatrixUnexpectedResponseError < MatrixError
  end
end
