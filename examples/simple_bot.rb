#!/usr/bin/env ruby
# frozen_string_literal: true

require 'matrix_sdk'

# A filter to simplify syncs
BOT_FILTER = {
  presence: { types: [] },
  account_data: { types: [] },
  room: {
    ephemeral: { types: [] },
    state: {
      types: ['m.room.*'],
      lazy_load_members: true
    },
    timeline: {
      types: ['m.room.message']
    },
    account_data: { types: [] }
  }
}.freeze

class MatrixBot
  def initialize(hs_url, access_token)
    @hs_url = hs_url
    @token = access_token
  end

  def run
    # Join all invited rooms
    client.on_invite_event.add_handler { |ev| client.join_room(ev[:room_id]) }

    # Run an empty sync to get to a `since` token without old data.
    # Storing the `since` token is also valid for bot use-cases, but in the
    # case of ping responses there's never any need to reply to old data.
    empty_sync = deep_copy(BOT_FILTER)
    empty_sync[:room].map { |_k, v| v[:types] = [] }
    client.sync filter: empty_sync

    # Read all message events
    client.on_event.add_handler('m.room.message') { |ev| on_message(ev) }

    loop do
      client.sync filter: BOT_FILTER
    rescue StandardError => e
      puts "Failed to sync - #{e.class}: #{e}"
      sleep 5
    end
  end

  def on_message(message)
    return unless message.content[:msgtype] == 'm.text'

    msgstr = message.content[:body]

    return unless msgstr =~ /^!(ping|echo)\s*/

    handle_ping(message) if msgstr.start_with? '!ping'
    handle_echo(message) if msgstr.start_with? '!echo'
  end

  def handle_ping(message)
    # Cut ping message to max 20 characters, and remove whitespace
    msgstr = message.content[:body]
                    .gsub(/!ping\s*/, '')
                    .[](0..20)
                    .strip

    msgstr = " \"#{msgstr}\"" unless msgstr.empty?

    room = client.ensure_room message.room_id
    sender = client.get_user message.sender

    origin_ts = Time.at(message[:origin_server_ts] / 1000.0)
    diff = Time.now - origin_ts

    puts "[#{Time.now.strftime '%H:%M'}] <#{sender.id} in #{room.id} @ #{(diff * 1000).round(2)}ms> \"#{message.content[:body]}\""

    plaintext = '%<sender>s: Pong! (ping%<msg>s took %<time>s to arrive)'
    html = '<a href="https://matrix.to/#/%<sender>s">%<sender>s</a>: Pong! (<a href="https://matrix.to/#/%<room>s/%<event>s">ping</a>%<msg>s took %<time>s to arrive)'

    milliseconds = (diff * 1000).to_i
    formatdata = {
      sender: sender.id,
      room: room.id,
      event: message.event_id,
      time: duration_format(milliseconds),
      msg: msgstr
    }

    from_id = MatrixSdk::MXID.new(sender.id)

    eventdata = {
      body: format(plaintext, formatdata),
      format: 'org.matrix.custom.html',
      formatted_body: format(html, formatdata),
      msgtype: 'm.notice',
      'm.relates_to': {
        event_id: formatdata[:event],
        from: from_id.homeserver,
        ms: milliseconds,
        rel_type: 'xyz.maubot.pong'
      },
      pong: {
        from: from_id.homeserver,
        ms: milliseconds,
        ping: formatdata[:event]
      }
    }

    client.api.send_message_event(room.id, 'm.room.message', eventdata)
  end

  def handle_echo(message)
    msgstr = message.content[:body]
    msgstr.gsub!(/!echo\s*/, '')

    return if msgstr.empty?

    room = client.ensure_room message.room_id
    sender = client.get_user message.sender

    puts "[#{Time.now.strftime '%H:%M'}] <#{sender.id} in #{room.id}> \"#{message.content[:body]}\""

    room.send_notice(msgstr)
  end

  private

  def client
    @client ||= MatrixSdk::Client.new @hs_url, access_token: @token, client_cache: :none
  end

  def deep_copy(hash)
    Marshal.load(Marshal.dump(hash))
  end

  MS_PER_DAY = 86_400_000.0
  MS_PER_HOUR = 3_600_000.0
  MS_PER_MINUTE = 60_000.0
  MS_PER_SECOND = 1_000.0

  def duration_format(duration_ms)
    return "#{duration_ms} ms" if duration_ms <= 9000

    timestr = ''

    if duration_ms > MS_PER_DAY * 1.1
      days = (duration_ms / MS_PER_DAY).floor
      puts days
      duration_ms -= days * MS_PER_DAY
      puts duration_ms
      if days.positive?
        timestr += "#{days} days#{days > 1 ? 's' : ''} "
      end
    end

    if duration_ms > MS_PER_HOUR * 1.1
      hours = (duration_ms / MS_PER_HOUR).floor
      puts hours
      duration_ms -= hours * MS_PER_HOUR
      puts duration_ms
      if hours.positive?
        timestr += 'and ' unless timestr.empty?
        timestr += "#{hours} hour#{hours > 1 ? 's' : ''} "
      end
    end

    if duration_ms > MS_PER_MINUTE * 1.1
      minutes = (duration_ms / MS_PER_MINUTE).floor
      puts minutes
      duration_ms -= minutes * MS_PER_MINUTE
      puts duration_ms
      if minutes.positive?
        timestr += 'and ' unless timestr.empty?
        timestr += "#{minutes} minute#{minutes > 1 ? 's' : ''} "
      end
    end

    seconds = (duration_ms / MS_PER_SECOND).round(timestr.empty? ? 1 : 0)
    puts seconds
    seconds = seconds.round if seconds.round == seconds
    if seconds.positive?
      timestr += 'and ' unless timestr.empty?
      timestr += "#{seconds} second#{seconds > 1 ? 's' : ''} "
    end

    timestr.rstrip
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
