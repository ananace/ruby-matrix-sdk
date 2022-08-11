module MatrixSdk::Util
  class AccountDataCache
    extend MatrixSdk::Extensions
    extend MatrixSdk::Util::Tinycache

    attr_reader :client, :room

    attr_accessor :cache_time

    ignore_inspect :client, :room, :tinycache_adapter

    def initialize(client, room: nil, cache_time: 1 * 60, **params)
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

    def delete(key)
      if room
        client.api.set_room_account_data(client.mxid, room.id, key.to_s, {})
      else
        client.api.set_account_data(client.mxid, key.to_s, {})
      end
      tinycache_adapter.delete(key.to_s)
    end

    def [](key)
      tinycache_adapter.fetch(key.to_s, expires_in: @cache_time) do
        if room
          client.api.get_room_account_data(client.mxid, room.id, key.to_s)
        else
          client.api.get_account_data(client.mxid, key.to_s)
        end
      rescue MatrixSdk::MatrixNotFoundError
        {}
      end
    end

    def []=(key, value)
      if room
        client.api.set_room_account_data(client.mxid, room.id, key.to_s, value)
      else
        client.api.set_account_data(client.mxid, key.to_s, value)
      end
      tinycache_adapter.write(key.to_s, value)
    end
  end
end
