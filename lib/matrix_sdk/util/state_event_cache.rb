# frozen_string_literal: true

module MatrixSdk::Util
  class StateEventCache
    extend MatrixSdk::Extensions
    extend MatrixSdk::Util::Tinycache
    include Enumerable

    attr_reader :room

    attr_accessor :cache_time

    ignore_inspect :client, :room, :tinycache_adapter

    def initialize(room, cache_time: 30 * 60, **_params)
      raise ArgumentError, 'Must be given a Room instance' unless room.is_a? MatrixSdk::Room

      @room = room
      @cache_time = cache_time
    end

    def client
      @room.client
    end

    def reload!
      tinycache_adapter.clear
    end

    def keys
      tinycache_adapter.send(:cache).keys.map do |type|
        real_type = type.split('|').first
        state_key = type.split('|').last
        state_key = nil if state_key == real_type

        [real_type, state_key]
      end
    end

    def values
      keys.map { |key| tinycache_adapter.read(key) }
    end

    def size
      keys.count
    end

    def key?(type, key = nil)
      keys.key?("#{type}#{key ? "|#{key}" : ''}")
    end

    def expire(type, key = nil)
      tinycache_adapter.expire("#{type}#{key ? "|#{key}" : ''}")
    end

    def each(live: false)
      return to_enum(__method__, live: live) { keys.count } unless block_given?

      keys.each do |type|
        real_type = type.split('|').first
        state_key = type.split('|').last
        state_key = nil if state_key == real_type

        v = live ? self[real_type, key: state_key] : tinycache_adapter.read(type)
        # hash = v.hash
        yield [real_type, state_key], v
        # self[key] = v if hash != v.hash
      end
    end

    def delete(type, key = nil)
      type = type.to_s unless type.is_a? String
      client.api.set_room_state(room.id, type, {}, **{ state_key: key }.compact)
      tinycache_adapter.delete("#{type}#{key ? "|#{key}" : ''}")
    end

    def [](type, key = nil)
      type = type.to_s unless type.is_a? String
      tinycache_adapter.fetch("#{type}#{key ? "|#{key}" : ''}", expires_in: @cache_time) do
        client.api.get_room_state(room.id, type, **{ key: key }.compact)
      rescue MatrixSdk::MatrixNotFoundError
        {}
      end
    end

    def []=(type, key = nil, value) # rubocop:disable Style/OptionalArguments Not possible to put optional last
      type = type.to_s unless type.is_a? String
      client.api.set_room_state(room.id, type, value, **{ state_key: key }.compact)
      tinycache_adapter.write("#{type}#{key ? "|#{key}" : ''}", value)
    end
  end
end
