# frozen_string_literal: true

module MatrixSdk::Util
  class TinycacheAdapter
    extend MatrixSdk::Extensions

    attr_accessor :config, :client

    ignore_inspect :client

    def initialize
      @config = {}

      clear
    end

    def read(key)
      cache[key]&.value
    end

    def write(key, value, expires_in: nil, cache_level: nil)
      expires_in ||= config.dig(key, :expires)
      expires_in ||= 24 * 60 * 60
      cache_level ||= client&.cache
      cache_level ||= :all
      cache_level = Tinycache::CACHE_LEVELS[cache_level] unless cache_level.is_a? Integer

      return value if cache_level < Tinycache::CACHE_LEVELS[config.dig(key, :level) || :none]

      cache[key] = Value.new(value, Time.now, Time.now + expires_in)
      value
    end

    def exist?(key)
      cache.key?(key)
    end

    def valid?(key)
      exist?(key) && !cache[key].expired?
    end

    def fetch(key, expires_in: nil, cache_level: nil, **_opts)
      expires_in ||= config.dig(key, :expires)
      cache_level ||= client&.cache
      cache_level ||= :all
      cache_level = Tinycache::CACHE_LEVELS[cache_level]

      return read(key) if exist?(key) && !cache[key].expired?

      value = yield
      write(key, value, expires_in: expires_in, cache_level: cache_level)
    end

    def delete(key)
      return false unless exist?(key)

      cache.delete key
      true
    end

    def clear
      @cache = {}
    end

    def cleanup
      @cache.select { |_, v| v.expired? }.each { |_, v| v.value = nil }
    end

    private

    Value = Struct.new(:value, :timestamp, :expires_at) do
      def expired?
        return false if expires_at.nil?

        Time.now > expires_at
      end
    end

    attr_reader :cache
  end
end
