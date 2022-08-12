# frozen_string_literal: true

module MatrixSdk::Util
  class AccountDataCache
    extend MatrixSdk::Extensions
    extend MatrixSdk::Util::Tinycache
    include Enumerable

    attr_reader :client, :room

    attr_accessor :cache_time

    ignore_inspect :client, :room, :tinycache_adapter

    def initialize(client, room: nil, cache_time: 1 * 60 * 60, **_params)
      raise ArgumentError, 'Must be given a Client instance' unless client.is_a? MatrixSdk::Client

      @client = client
      @cache_time = cache_time

      return unless room

      @room = room
      @room = client.ensure_room room unless @room.is_a? MatrixSdk::Room
    end

    def reload!
      tinycache_adapter.clear
    end

    def keys
      tinycache_adapter.send(:cache).keys
    end

    def values
      keys.map { |key| tinycache_adapter.read(key) }
    end

    def size
      keys.count
    end

    def key?(key)
      keys.key?(key.to_s)
    end

    def each(live: false)
      return to_enum(__method__, live: live) { keys.count } unless block_given?

      keys.each do |key|
        v = live ? self[key] : tinycache_adapter.read(key) 
        #hash = v.hash
        yield key, v
        #self[key] = v if hash != v.hash
      end
    end

    def delete(key)
      key = key.to_s unless key.is_a? String
      if room
        client.api.set_room_account_data(client.mxid, room.id, key, {})
      else
        client.api.set_account_data(client.mxid, key, {})
      end
      tinycache_adapter.delete(key)
    end

    def [](key)
      key = key.to_s unless key.is_a? String
      tinycache_adapter.fetch(key, expires_in: @cache_time) do
        if room
          client.api.get_room_account_data(client.mxid, room.id, key)
        else
          client.api.get_account_data(client.mxid, key)
        end
      rescue MatrixSdk::MatrixNotFoundError
        {}
      end
    end

    def []=(key, value)
      key = key.to_s unless key.is_a? String
      if room
        client.api.set_room_account_data(client.mxid, room.id, key, value)
      else
        client.api.set_account_data(client.mxid, key, value)
      end
      tinycache_adapter.write(key, value)
    end
  end
end
