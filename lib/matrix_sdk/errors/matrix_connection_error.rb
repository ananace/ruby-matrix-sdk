# frozen_string_literal: true

class MatrixSdk::MatrixConnectionError < MatrixSdk::MatrixError
  def self.class_by_code(code)
    return MatrixTimeoutError if code == 504

    MatrixConnectionError
  end
end
