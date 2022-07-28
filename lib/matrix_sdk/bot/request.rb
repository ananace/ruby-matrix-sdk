# frozen_string_literal: true

module MatrixSdk::Bot
  class Request
    attr_reader :bot, :event
    attr_writer :logger

    def initialize(bot, event)
      @bot = bot
      @event = event
    end

    def logger
      @logger || Logging.logger[self]
    end

    def client
      @bot.client
    end

    def room
      client.ensure_room(event[:room_id])
    end

    def sender
      client.get_user(event[:sender])
    end
  end
end
