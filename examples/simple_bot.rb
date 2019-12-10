#!/usr/bin/env ruby

require 'matrix_sdk'

# A filter to simplify syncs
BOT_FILTER = {
  presence: { senders: [], types: [] },
  account_data: { senders: [], types: [] },
  room: {
    ephemeral: { senders: [], types: [] },
    state: {
      types: ['m.room.*'],
      lazy_load_members: true
    },
    timeline: {
      types: ['m.room.message']
    },
    account_data: { senders: [], types: [] }
  }
}.freeze

class MatrixBot
  def initialize(hs_url, token)
    @hs_url = hs_url
    @token = token
  end

  def run
    # Join all invited rooms
    client.on_invite_event.add_handler { |ev| client.join_room(ev[:room_id]) }
    # Read all message events
    client.on_event.add_handler('m.room.message') { |ev| on_message(ev) }

    loop do
      begin
        client.sync filter: BOT_FILTER
        save_batch
      rescue MatrixSdk::MatrixError => e
        puts e
      end
    end
  end

  def on_message(message)
    room = client.ensure_room message.room_id
    sender = client.get_user message.sender

    return unless message.content[:body] == '!ping'

    puts "[#{Time.now.strftime '%H:%M'}] <#{sender.id} in #{room.id}> #{message.content[:body]}"

    origin_ts = Time.at(message[:origin_server_ts] / 1000.0)
    diff = Time.now - origin_ts

    plaintext = '%<sender>s: Pong! (ping took %<time>u ms to arrive)'
    html = '<a href="https://matrix.to/#/%<sender>s">%<sender>s</a>: Pong! (<a href="https://matrix.to/#/%<room>s/%<event>s">ping</a> took %<time>u ms to arrive)'

    formatdata = {
      sender: sender.id,
      room: room.id,
      event: message.event_id,
      time: (diff * 1000).to_i
    }

    from_id = MatrixSdk::MXID.new(sender.id)
    from_str = "#{from_id.domain}#{from_id.port ? ":#{from_id.port}" : ''}"

    eventdata = {
      body: format(plaintext, formatdata),
      format: 'org.matrix.custom.html',
      formatted_body: format(html, formatdata),
      msgtype: 'm.notice',
      pong: {
        from: from_str,
        ms: formatdata[:time],
        ping: formatdata[:event]
      }
    }

    client.api.send_message_event(room.id, 'm.room.message', eventdata)
  end

  private

  def client
    @client ||= MatrixSdk::Client.new @hs_url, access_token: @token, client_cache: :none, next_batch: last_batch
  end

  def last_batch
    @last_batch ||= File.read('/tmp/testbot.batch')
  rescue Errno::ENOENT
    nil
  end

  def save_batch
    File.write('/tmp/testbot.batch', client.next_batch)
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
