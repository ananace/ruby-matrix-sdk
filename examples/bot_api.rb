#!/usr/bin/env ruby
# frozen_string_literal: true

require 'matrix_sdk/bot/main'

set :bot_name, 'pingbot'

command :echo, desc: 'Echoes the given message back as an m.notice' do |message|
  logger.debug "Received !echo from #{sender}"

  room.send_notice(message)
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
    duration_ms -= days * MS_PER_DAY
    puts duration_ms
    if days.positive?
      timestr += "#{days} days#{days > 1 ? 's' : ''} "
    end
  end

  if duration_ms > MS_PER_HOUR * 1.1
    hours = (duration_ms / MS_PER_HOUR).floor
    duration_ms -= hours * MS_PER_HOUR
    puts duration_ms
    if hours.positive?
      timestr += 'and ' unless timestr.empty?
      timestr += "#{hours} hour#{hours > 1 ? 's' : ''} "
    end
  end

  if duration_ms > MS_PER_MINUTE * 1.1
    minutes = (duration_ms / MS_PER_MINUTE).floor
    duration_ms -= minutes * MS_PER_MINUTE
    puts duration_ms
    if minutes.positive?
      timestr += 'and ' unless timestr.empty?
      timestr += "#{minutes} minute#{minutes > 1 ? 's' : ''} "
    end
  end

  seconds = (duration_ms / MS_PER_SECOND).round(timestr.empty? ? 1 : 0)
  seconds = seconds.round if seconds.round == seconds
  if seconds.positive?
    timestr += 'and ' unless timestr.empty?
    timestr += "#{seconds} second#{seconds > 1 ? 's' : ''} "
  end

  timestr.rstrip
end

command :ping, desc: 'Runs a ping with a given ID and returns the request time' do |message = nil|
  origin_ts = Time.at(event[:origin_server_ts] / 1000.0)
  diff = Time.now - origin_ts

  logger.info "[#{Time.now.strftime '%H:%M'}] <#{sender.id} in #{room.id} @ #{(diff * 1000).round(2)}ms> #{message.inspect}"

  plaintext = '%<sender>s: Pong! (ping%<msg>s took %<time>s to arrive)'
  html = '<a href="https://matrix.to/#/%<sender>s">%<sender>s</a>: Pong! (<a href="https://matrix.to/#/%<room>s/%<event>s">ping</a>%<msg>s took %<time>s to arrive)'

  milliseconds = (diff * 1000).to_i
  message = " \"#{message}\"" if message

  formatdata = {
    sender: sender.id,
    room: room.id,
    event: event.event_id,
    time: duration_format(milliseconds),
    msg: message
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
