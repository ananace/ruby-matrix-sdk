# frozen_string_literal: true

class MatrixSdk::MatrixRequestError < MatrixSdk::MatrixError
  attr_reader :code, :data, :httpstatus, :message
  alias error message

  def self.class_by_code(code)
    code = code.to_i

    return MatrixSdk::MatrixNotAuthorizedError if code == 401
    return MatrixSdk::MatrixForbiddenError if code == 403
    return MatrixSdk::MatrixNotFoundError if code == 404
    return MatrixSdk::MatrixConflictError if code == 409
    return MatrixSdk::MatrixTooManyRequestsError if code == 429

    MatrixSdk::MatrixRequestError
  end

  def self.new_by_code(data, code)
    class_by_code(code).new(data, code)
  end

  def initialize(error, status)
    @code = error[:errcode]
    @httpstatus = status
    @message = error[:error]
    @data = error.reject { |k, _v| %i[errcode error].include? k }

    super error[:error]
  end

  def to_s
    "HTTP #{httpstatus} (#{code}): #{message}"
  end
end
