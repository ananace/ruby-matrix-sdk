# frozen_string_literal: true

module MatrixSdk::Util
  class TinycacheAdapter
    attr_accessor :config, :client

    def initialize
      @config = {}

      clear
    end

    def read(key)
      cache[key]&.value
    end

    def write(key, value, expires_in: nil, cache_level: nil)
      expires_in ||= config.dig(key, :expires)
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
      @cache.delete_if { |_, v| v.expired? }
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
