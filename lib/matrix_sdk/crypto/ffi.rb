# frozen_string_literal: true

require 'ffi'

module MatrixSdk::Crypto
  class FFI
    module RustCrypto
      extend ::FFI::Library
      ffi_lib 'matrix_sdk_ffi'

      callback :log_callback, [:string], :void
      attach_function :set_logger, [:log_callback], :void

      class RustBuffer < ::FFI::ManagedStruct
        layout :capacity, :long,
               :length, :long,
               :data, :pointer

        def self.create(size = 0)
          new RustCrypto.ffi_matrix_sdk_crypto_rustbuffer_alloc(size)
        end

        def self.release(ptr)
          RustCrypto.ffi_matrix_sdk_crypto_rustbuffer_free(ptr)
        end
      end

      class RustCallStatus < ::FFI::Struct
        layout :code, :byte,
               :error_buf, RustBuffer

        def error_buf
          new RustBuffer(self[:error_buf])
        end
      end

      class OlmMachine < ::FFI::ManagedStruct
        def self.create(mxid, devid, path = nil, password: nil)
          password = password.to_s unless password.nil?
          path ||= begin
            require 'tmpdir'
            Dir.mktmpdir
          end

          RustCrypto.ffi_matrix_sdk_crypto_olmmachine_alloc(mxid.to_s, devid.to_s, path.to_s, password)
        end

        def self.release(ptr)
          RustCrypto.ff_i
        end
      end
    end

    RustCrypto::Logger = Proc.new do |string|
      ::Logging.logger[MatrixSdk::Crypto::FFI].info string
    end
    RustCrypto.set_logger RustCrypto::Logger

    attr_accessor :client
    attr_reader :machine

    def initialize
      raise NotImplementedError, "Still needs matrix-rust-sdk-crypto work"

      machine = RustCrypto::OlmMachine.new
    end

    def pre_sync(_params)
      # client.api
    end

    def post_sync(data)
      # client.receive_sync_changes(data.dig(:to_device).to_json, )
    end
  end
end
