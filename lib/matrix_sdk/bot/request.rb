# frozen_string_literal: true

module MatrixSdk::Bot
  class Request
    extend MatrixSdk::Extensions

    attr_reader :bot, :event
    attr_writer :logger

    ignore_inspect :bot

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

    # Helpers for checking power levels
    def sender_admin?
      sender.admin? room
    end

    def sender_moderator?
      sender.moderator? room
    end
  end
end
