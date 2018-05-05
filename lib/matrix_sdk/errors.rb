module MatrixSdk
  class MatrixError
    attr_reader :errcode, :error, :httpstatus

    def initialize(error, status)
      @errcode = error[:errcode]
      @error = error[:error]
      @httpstatus = status
    end

    def to_s
      "#{errcode}: #{error}"
    end
  end
end
