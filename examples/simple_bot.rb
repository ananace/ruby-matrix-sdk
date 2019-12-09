#!/usr/bin/env ruby

require 'matrix_sdk'

# A filter to simplify syncs
BOT_FILTER = {
  presence: { senders: [], types: [] },
  account_data: { senders: [], types: [] },
  room: {
    ephemeral: { senders: [], types: [] },
    state: {
      limit: 5,
      types: ['m.room.*'],
      lazy_load_members: true
    },
    timeline: {
      limit: 5,
      types: ['m.room.message']
    },
    account_data: { senders: [], types: [] }
  }
}.freeze

class MatrixBot
  def initialize(hs_url, token)
    @hs_url = hs_url
    @token = token

    # TODO: Store this between runs for actual usage.
    @last_batch = nil
  end

  def run
    # Join all invited rooms
    client.on_invite_event.add_handler { |ev| client.join_room(ev[:room_id]) }
    # Read all message events
    client.on_event.add_handler('m.room.message') { |ev| on_message(ev) }

    loop do
      begin
        client.sync filter: BOT_FILTER
      rescue MatrixSdk::MatrixError => e
        puts e
      end
    end
  end

  def on_message(message)
    room = client.ensure_room message.room_id
    sender = client.get_user message.sender

    return unless message.content[:body] == '!pingr'

    puts "[#{Time.now.strftime '%H:%M'}] <#{sender.id} in #{room.id}> #{message.content[:body]}"

    origin_ts = Time.at(message[:origin_server_ts] / 1000.0)
    diff = Time.now - origin_ts

    room.send_notice("#{sender.user_id}: Pong! (Ping took #{(diff * 1000).to_i}ms)")
  end

  private

  def client
    @client ||= MatrixSdk::Client.new @hs_url, access_token: @token, client_cache: :none
  end
end

if $PROGRAM_NAME == __FILE__
  raise "Usage: #{$PROGRAM_NAME} [-d] homeserver_url access_token" unless ARGV.length >= 2

  if ARGV.first == '-d'
    Thread.abort_on_exception = true
    MatrixSdk.debug!
    ARGV.shift
  end

  bot = MatrixBot.new ARGV[0], ARGV[1]
  bot.run
end
