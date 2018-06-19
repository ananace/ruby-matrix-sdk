#!/usr/bin/env ruby

require 'io/console'
require 'matrix_sdk'

class SimpleClient < MatrixSdk::Client
  def initialize(hs_url)
    super hs_url, sync_filter_limit: 10

    @pls = {}
  end

  def add_listener(room)
    room.on_event.add_handler { |ev| on_message(room, ev) }
  end

  def run
    start_listener_thread
  end

  private

  def get_user_level(room, mxid)
    levels = @pls[room.id] ||= api.get_power_levels(room.id)[:users]
    levels[mxid.to_sym]
  end

  def on_message(room, event)
    case event.type
    when 'm.room.member'
      puts "[#{Time.now.strftime '%H:%M'}] #{event[:content][:displayname]} joined." if event.membership == 'join'
    when 'm.room.message'
      user = get_user event.sender
      admin_level = get_user_level(room, user.id) || 0
      prefix = (admin_level >= 100 ? '@' : (admin_level >= 50 ? '+' : ' '))
      if %w[m.text m.notice].include? event.content[:msgtype]
        notice = event.content[:msgtype] == 'm.notice'
        puts "[#{Time.now.strftime '%H:%M'}] <#{prefix}#{user.display_name}> #{"\033[1;30m" if notice}#{event.content[:body]}#{"\033[0m" if notice}"
      elsif event[:content][:msgtype] == 'm.emote'
        puts "[#{Time.now.strftime '%H:%M'}] *#{prefix}#{user.display_name} #{event.content[:body]}"
      else
        puts "[#{Time.now.strftime '%H:%M'}] <#{prefix}#{user.display_name}> (#{event.content[:msgtype]}) #{event.content[:body]} - #{api.get_download_url event.content[:url]}"
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  raise "Usage: #{$PROGRAM_NAME} [-d] homeserver_url room_id_or_alias" unless ARGV.length >= 2
  begin
    if ARGV.first == '-d'
      MatrixSdk.debug!
      ARGV.shift
    end

    client = SimpleClient.new ARGV.first
    ARGV.shift

    print 'Username: '
    user = STDIN.gets.strip
    puts 'Password: '
    password = STDIN.noecho(&:gets).strip

    puts 'Logging in...'
    client.login(user, password, sync_timeout: 5)

    puts 'Finding room...'
    room = client.find_room(ARGV.last)
    room ||= begin
      puts 'Joining room...'
      client.join_room(ARGV.last)
    end

    client.add_listener(room)

    puts 'Starting listener'
    client.run

    puts 'Entering main loop'
    loop do
      print '> '
      msg = STDIN.gets.strip
      break if msg.start_with? '/quit'

      if msg.start_with? '/me'
        room.send_emote msg.gsub(/\/me\s*/, '')
      else
        room.send_text msg
      end
    end
  rescue Interrupt
    puts "Interrupted, exiting..."
  ensure
    client.logout if client && client.logged_in?
  end
end
