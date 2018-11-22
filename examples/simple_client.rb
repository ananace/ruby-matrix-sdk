#!/usr/bin/env ruby

require 'io/console'
require 'matrix_sdk'

# A filter to only discover joined rooms
ROOM_DISCOVERY_FILTER = {
  event_fields: %w[sender membership],
  presence: { senders: [], types: [] },
  account_data: { senders: [], types: [] },
  room: {
    ephemeral: { senders: [], types: [] },
    state: {
      senders: [],
      types: [
        'm.room.aliases',
        'm.room.canonical_alias',
        'm.room.member'
      ]
    },
    timeline: { senders: [], types: [] },
    account_data: { senders: [], types: [] }
  }
}.freeze

# A filter to only retrieve messages from rooms
ROOM_STATE_FILTER = {
  presence: { senders: [], types: [] },
  account_data: { senders: [], types: [] },
  room: {
    ephemeral: { senders: [], types: [] },
    state: {
      types: ['m.room.member']
    },
    timeline: {
      types: ['m.room.message']
    },
    account_data: { senders: [], types: [] }
  }
}.freeze


class SimpleClient < MatrixSdk::Client
  def initialize(hs_url)
    super hs_url, sync_filter_limit: 10

    @pls = {}
    @tracked_rooms = []
    @filter = ROOM_STATE_FILTER.dup
  end

  def add_listener(room)
    room.on_event.add_handler { |ev| on_message(room, ev) }
    @tracked_rooms << room.id
  end

  def run
    # Only track messages from the listened rooms
    @filter[:room][:rooms] = @tracked_rooms
    start_listener_thread(filter: @filter.to_json)
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
      prefix = ' '
      prefix = '+' if admin_level >= 50
      prefix = '@' if admin_level >= 100
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
    client.login(user, password, no_sync: true)

    # Only retrieve list of joined room in first sync
    sync_filter = client.sync_filter.merge(ROOM_DISCOVERY_FILTER)
    sync_filter[:room][:state][:senders] << client.mxid
    client.listen_for_events(5, filter: sync_filter.to_json)

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
    puts 'Interrupted, exiting...'
  ensure
    client.logout if client && client.logged_in?
  end
end
