# frozen_string_literal: true

require 'matrix_sdk'
require 'matrix_sdk/util/events'
require 'matrix_sdk/util/tinycache'

module MatrixSdk
  # A class for tracking the information about a room on Matrix
  class Room
    extend MatrixSdk::Extensions
    extend MatrixSdk::Util::Tinycache
    include MatrixSdk::Logging

    # @!attribute [rw] event_history_limit
    #   @return [Fixnum] the limit of events to keep in the event log
    attr_accessor :event_history_limit
    # @!attribute [r] id
    #   @return [String] the internal ID of the room
    # @!attribute [r] client
    #   @return [Client] the client for the room
    # @!attribute [r] events
    #   @return [Array(Object)] the last +event_history_limit+ events to arrive in the room
    #   @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-sync
    #        The timeline events are what will end up in here
    attr_reader :id, :client, :events

    # @!method inspect
    #   An inspect method that skips a handful of instance variables to avoid
    #   flooding the terminal with debug data.
    #   @return [String] a regular inspect string without the data for some variables
    ignore_inspect :client, :events, :prev_batch, :logger, :tinycache_adapter

    # Requires heavy lookups, so they're cached for an hour
    cached :joined_members, cache_level: :all, expires_in: 60 * 60

    # Only cache unfiltered requests for aliases and members
    cached :aliases, unless: proc { |args| args.any? }, cache_level: :all, expires_in: 60 * 60
    cached :all_members, unless: proc { |args| args.any? }, cache_level: :all, expires_in: 60 * 60

    # Much simpler to look up, and lighter data-wise, so the cache is wider
    cached :canonical_alias, :name, :avatar_url, :topic, :guest_access, :join_rule, :power_levels, cache_level: :some, expires_in: 15 * 60

    alias room_id id
    alias members joined_members

    # Create a new room instance
    #
    # @note This method isn't supposed to be used directly, rather rooms should
    #       be retrieved from the Client abstraction.
    #
    # @param client [Client] The underlying connection
    # @param room_id [MXID] The room ID
    # @param data [Hash] Additional data to assign to the room
    # @option data [String] :name The current name of the room
    # @option data [String] :topic The current topic of the room
    # @option data [String,MXID] :canonical_alias The canonical alias of the room
    # @option data [Array(String,MXID)] :aliases All non-canonical aliases of the room
    # @option data [:invite,:public,:knock] :join_rule The join rule for the room
    # @option data [:can_join,:forbidden] :guest_access The guest access setting for the room
    # @option data [Boolean] :world_readable If the room is readable by the entire world
    # @option data [Array(User)] :members The list of joined members
    # @option data [Array(Object)] :events The list of current events in the room
    # @option data [Boolean] :members_loaded If the list of members is already loaded
    # @option data [Integer] :event_history_limit (10) The limit of events to store for the room
    # @option data [String,URI] :avatar_url The avatar URL for the room
    # @option data [String] :prev_batch The previous batch token for backfill
    def initialize(client, room_id, data = {})
      if client.is_a? Room
        copy = client
        client = copy.client
        room_id = copy.id
        # data = copy.attributes
      end

      raise ArgumentError, 'Must be given a Client instance' unless client.is_a? Client

      @client = client
      tinycache_adapter.client = client
      room_id = MXID.new room_id unless room_id.is_a?(MXID)
      raise ArgumentError, 'room_id must be a valid Room ID' unless room_id.room_id?

      @events = []
      @event_history_limit = 10
      @room_type = nil

      @prev_batch = nil

      data.each do |k, v|
        next if %i[client].include? k

        if respond_to?("#{k}_cached?".to_sym) && send("#{k}_cached?".to_sym)
          tinycache_adapter.write(k, v)
        elsif instance_variable_defined? "@#{k}"
          instance_variable_set("@#{k}", v)
        end
      end

      @id = room_id.to_s

      logger.debug "Created room #{room_id}"
    end

    #
    # Casting operators
    #

    def to_space
      return nil unless space?

      Rooms::Space.new self, nil
    end

    def to_s
      prefix = canonical_alias if canonical_alias_has_value?
      prefix ||= id
      return "#{prefix} | #{name}" if name_has_value?

      prefix
    end

    #
    # Event handlers
    #

    # @!attribute [r] on_event
    #   @return [EventHandlerArray] The list of event handlers for all events
    def on_event
      ensure_room_handlers[:event]
    end

    # @!attribute [r] on_state_event
    #   @return [EventHandlerArray] The list of event handlers for only state events
    def on_state_event
      ensure_room_handlers[:state_event]
    end

    # @!attribute [r] on_ephemeral_event
    #   @return [EventHandlerArray] The list of event handlers for only ephemeral events
    def on_ephemeral_event
      ensure_room_handlers[:ephemeral_event]
    end

    #
    # State readers
    #

    # Gets a human-readable name for the room
    #
    # This will return #name or #canonical_alias if they've been set,
    # otherwise it will query the API for members and generate a string from
    # a subset of their names.
    #
    # @return [String] a human-readable name for the room
    # @note This method will populate the #members list if it has to fall back
    #       to the member name generation.
    def display_name
      return name if name
      return canonical_alias if canonical_alias

      members = joined_members
                .reject { |m| m.user_id == client.mxid }
                .map(&:display_name)

      return members.first if members.one?
      return "#{members.first} and #{members.last}" if members.count == 2
      return "#{members.first} and #{members.count - 1} others" if members.count > 2

      'Empty Room'
    end

    # @return [String, nil] the canonical alias of the room
    def canonical_alias
      client.api.get_room_state(id, 'm.room.canonical_alias')[:alias]
    rescue MatrixSdk::MatrixNotFoundError
      nil
    end

    # Populates and returns the #members array
    #
    # @return [Array(User)] The list of members in the room
    def joined_members
      client.api.get_room_joined_members(id)[:joined].map do |mxid, data|
        User.new(client, mxid.to_s,
                 display_name: data.fetch(:display_name, nil),
                 avatar_url: data.fetch(:avatar_url, nil))
      end
    end

    # Get all members (member events) in the room
    #
    # @note This will also count members who've knocked, been invited, have left, or have been banned.
    #
    # @param params [Hash] Additional query parameters to pass to the room member listing - e.g. for filtering purposes.
    #
    # @return [Array(User)] The complete list of members in the room, regardless of membership state
    def all_members(**params)
      client.api.get_room_members(id, **params)[:chunk].map { |ch| client.get_user(ch[:state_key]) }
    end

    # Gets the current name of the room, querying the API if necessary
    #
    # @note Will cache the current name for 15 minutes
    #
    # @return [String,nil] The room name - if any
    def name
      client.api.get_room_name(id)[:name]
    rescue MatrixNotFoundError
      # No room name has been specified
      nil
    end

    # Checks if the room is a direct message / 1:1 room
    #
    # @param members_only [Boolean] Should directness only care about member count?
    # @return [Boolean]
    def dm?(members_only: false)
      return true if !members_only && client.direct_rooms.any? { |_uid, rooms| rooms.include? id.to_s }

      joined_members.count <= 2
    end

    # Mark a room as a direct (1:1) message Room
    def dm=(direct)
      rooms = client.direct_rooms
      dirty = false
      list_for_room = (rooms[id.to_s] ||= [])
      if direct && !list_for_room.include?(id.to_s)
        list_for_room << id.to_s
        dirty = true
      elsif !direct && list_for_room.include?(id.to_s)
        list_for_room.delete id.to_s
        rooms.delete id.to_s if list_for_room.empty?
        dirty = true
      end
      client.api.set_account_data(client.mxid, 'm.direct', rooms) if dirty
    end

    # Gets the avatar url of the room - if any
    #
    # @return [String,nil] The avatar URL - if any
    def avatar_url
      client.api.get_room_avatar(id)[:url]
    rescue MatrixNotFoundError
      # No avatar has been set
      nil
    end

    # Gets the room topic - if any
    #
    # @return [String,nil] The topic of the room
    def topic
      client.api.get_room_topic(id)[:topic]
    rescue MatrixNotFoundError
      # No room name has been specified
      nil
    end

    # Gets the guest access rights for the room
    #
    # @return [:can_join,:forbidden] The current guest access right
    def guest_access
      client.api.get_room_guest_access(id)[:guest_access]&.to_sym
    end

    # Gets the join rule for the room
    #
    # @return [:public,:knock,:invite,:private] The current join rule
    def join_rule
      client.api.get_room_join_rules(id)[:join_rule]&.to_sym
    end

    # Checks if +guest_access+ is set to +:can_join+
    def guest_access?
      guest_access == :can_join
    end

    # Checks if +join_rule+ is set to +:invite+
    def invite_only?
      join_rule == :invite
    end

    # Checks if +join_rule+ is set to +:knock+
    def knock_only?
      join_rule == :knock
    end

    # Gets the history visibility of the room
    #
    # @return [:invited,:joined,:shared,:world_readable] The current history visibility for the room
    def history_visibility
      client.api.get_room_state(id, 'm.room.history_visibility')[:history_visibility]&.to_sym
    end

    # Checks if the room history is world readable
    #
    # @return [Boolean] If the history is world readable
    def world_readable?
      history_visibility == :world_readable
    end
    alias world_readable world_readable?

    # Gets the room aliases
    #
    # @param canonical_only [Boolean] Should the list of aliases only contain the canonical ones
    # @return [Array[String]] The assigned room aliases
    def aliases(canonical_only: true)
      canonical = client.api.get_room_state(id, 'm.room.canonical_alias') rescue {}
      aliases = ([canonical[:alias]].compact + (canonical[:alt_aliases] || [])).uniq.sort
      return aliases if canonical_only

      (aliases + client.api.get_room_aliases(id).aliases).uniq.sort
    end

    #
    # Message handling
    #

    # Sends a plain-text message to the room
    #
    # @param text [String] the message to send
    def send_text(text)
      client.api.send_message(id, text)
    end

    # Sends a custom HTML message to the room
    #
    # @param html [String] the HTML message to send
    # @param body [String,nil] a plain-text representation of the object
    #        (Will default to the HTML with all tags stripped away)
    # @param msgtype [String] ('m.text') The message type for the message
    # @param format [String] ('org.matrix.custom.html') The message format
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-room-message-msgtypes
    #      Possible message types as defined by the spec
    def send_html(html, body = nil, msgtype: nil, format: nil)
      content = {
        body: body || html.gsub(/<\/?[^>]*>/, ''),
        msgtype: msgtype || 'm.text',
        format: format || 'org.matrix.custom.html',
        formatted_body: html
      }

      client.api.send_message_event(id, 'm.room.message', content)
    end

    # Sends an emote (/me) message to the room
    #
    # @param text [String] the emote to send
    def send_emote(text)
      client.api.send_emote(id, text)
    end

    # Sends a link to a generic file to the room
    #
    # @param url [String,URI] the URL to the file
    # @param name [String] the name of the file
    # @param file_info [Hash] extra information about the file
    # @option file_info [String] :mimetype the MIME type of the file
    # @option file_info [Integer] :size the size of the file in bytes
    # @option file_info [String,URI] :thumbnail_url the URL to a thumbnail of the file
    # @option file_info [Hash] :thumbnail_info ThumbnailInfo about the thumbnail file
    # @note The URLs should all be of the 'mxc://' schema
    def send_file(url, name, file_info = {})
      client.api.send_content(id, url, name, 'm.file', extra_information: file_info)
    end

    # Sends a notice (bot) message to the room
    #
    # @param text [String] the notice to send
    def send_notice(text)
      client.api.send_notice(id, text)
    end

    # Sends a link to an image to the room
    #
    # @param url [String,URI] the URL to the image
    # @param name [String] the name of the image
    # @param image_info [Hash] extra information about the image
    # @option image_info [Integer] :h the height of the image in pixels
    # @option image_info [Integer] :w the width of the image in pixels
    # @option image_info [String] :mimetype the MIME type of the image
    # @option image_info [Integer] :size the size of the image in bytes
    # @option image_info [String,URI] :thumbnail_url the URL to a thumbnail of the image
    # @option image_info [Hash] :thumbnail_info ThumbnailInfo about the thumbnail image
    # @note The URLs should all be of the 'mxc://' schema
    def send_image(url, name, image_info = {})
      client.api.send_content(id, url, name, 'm.image', extra_information: image_info)
    end

    # Sends a location object to the room
    #
    # @param geo_uri [String,URI] the geo-URL (e.g. geo:<coords>) of the location
    # @param name [String] the name of the location
    # @param thumbnail_url [String,URI] the URL to a thumbnail image of the location
    # @param thumbnail_info [Hash] a ThumbnailInfo for the location thumbnail
    # @note The thumbnail URL should be of the 'mxc://' schema
    def send_location(geo_uri, name, thumbnail_url = nil, thumbnail_info = {})
      client.api.send_location(id, geo_uri, name, thumbnail_url: thumbnail_url, thumbnail_info: thumbnail_info)
    end

    # Sends a link to a video to the room
    #
    # @param url [String,URI] the URL to the video
    # @param name [String] the name of the video
    # @param video_info [Hash] extra information about the video
    # @option video_info [Integer] :duration the duration of the video in milliseconds
    # @option video_info [Integer] :h the height of the video in pixels
    # @option video_info [Integer] :w the width of the video in pixels
    # @option video_info [String] :mimetype the MIME type of the video
    # @option video_info [Integer] :size the size of the video in bytes
    # @option video_info [String,URI] :thumbnail_url the URL to a thumbnail of the video
    # @option video_info [Hash] :thumbnail_info ThumbnailInfo about the thumbnail of the video
    # @note The URLs should all be of the 'mxc://' schema
    def send_video(url, name, video_info = {})
      client.api.send_content(id, url, name, 'm.video', extra_information: video_info)
    end

    # Sends a link to an audio clip to the room
    #
    # @param url [String,URI] the URL to the audio clip
    # @param name [String] the name of the audio clip
    # @param audio_info [Hash] extra information about the audio clip
    # @option audio_info [Integer] :duration the duration of the audio clip in milliseconds
    # @option audio_info [String] :mimetype the MIME type of the audio clip
    # @option audio_info [Integer] :size the size of the audio clip in bytes
    # @note The URLs should all be of the 'mxc://' schema
    def send_audio(url, name, audio_info = {})
      client.api.send_content(id, url, name, 'm.audio', extra_information: audio_info)
    end

    # Sends a customized message to the Room
    #
    # @param body [String] The clear-text body of the message
    # @param content [Hash] The custom content of the message
    # @param msgtype [String] The type of the message, should be one of the known types (m.text, m.notice, m.emote, etc)
    def send_custom_message(body, content = {}, msgtype: nil)
      content.merge!(
        body: body,
        msgtype: msgtype || 'm.text'
      )

      client.api.send_message_event(id, 'm.room.message', content)
    end

    # Sends a custom timeline event to the Room
    #
    # @param type [String,Symbol] The type of the Event.
    #   For custom events, this should be written in reverse DNS format (e.g. com.example.event)
    # @param content [Hash] The contents of the message, this will be the
    #   :content key of the resulting event object
    # @see Protocols::CS#send_message_event
    def send_event(type, content = {})
      client.api.send_message_event(room.id, type, content)
    end

    # Redacts a message from the room
    #
    # @param event_id [String] the ID of the event to redact
    # @param reason [String,nil] the reason for the redaction
    def redact_message(event_id, reason = nil)
      client.api.redact_event(id, event_id, reason: reason)
      true
    end

    # Reports a message in the room
    #
    # @param event_id [MXID,String] The ID of the event to redact
    # @param reason [String] The reason for the report
    # @param score [Integer] The severity of the report in the range of -100 - 0
    def report_message(event_id, reason:, score: -100)
      client.api.report_event(id, event_id, reason: reason, score: score)
      true
    end

    # Backfills messages into the room history
    #
    # @param reverse [Boolean] whether to fill messages in reverse or not
    # @param limit [Integer] the maximum number of messages to backfill
    # @note This will trigger the `on_event` events as messages are added
    def backfill_messages(*args, reverse: false, limit: 10)
      # To be backwards-compatible
      if args.length == 2
        reverse = args.first
        limit = args.last
      end

      data = client.api.get_room_messages(id, @prev_batch, direction: :b, limit: limit)

      events = data[:chunk]
      events.reverse! unless reverse
      events.each do |ev|
        put_event(ev)
      end
      true
    end

    #
    # User Management
    #

    # Invites a user into the room
    #
    # @param user_id [String,User] the MXID of the user
    # @return [Boolean] wether the action succeeded
    def invite_user(user_id)
      user_id = user_id.id if user_id.is_a? MatrixSdk::User
      client.api.invite_user(id, user_id)
      true
    end

    # Kicks a user from the room
    #
    # @param user_id [String,User] the MXID of the user
    # @param reason [String] the reason for the kick
    # @return [Boolean] wether the action succeeded
    def kick_user(user_id, reason = '')
      user_id = user_id.id if user_id.is_a? MatrixSdk::User
      client.api.kick_user(id, user_id, reason: reason)
      true
    end

    # Bans a user from the room
    #
    # @param user_id [String,User] the MXID of the user
    # @param reason [String] the reason for the ban
    # @return [Boolean] wether the action succeeded
    def ban_user(user_id, reason = '')
      user_id = user_id.id if user_id.is_a? MatrixSdk::User
      client.api.ban_user(id, user_id, reason: reason)
      true
    end

    # Unbans a user from the room
    #
    # @param user_id [String,User] the MXID of the user
    # @return [Boolean] wether the action succeeded
    def unban_user(user_id)
      user_id = user_id.id if user_id.is_a? MatrixSdk::User
      client.api.unban_user(id, user_id)
      true
    end

    # Requests to be removed from the room
    #
    # @return [Boolean] wether the request succeeded
    def leave
      client.api.leave_room(id)
      client.instance_variable_get(:@rooms).delete id
      true
    end

    # Retrieves a custom entry from the room-specific account data
    #
    # @param type [String] the data type to retrieve
    # @return [Hash] the data that was stored under the given type
    def get_account_data(type)
      client.api.get_room_account_data(client.mxid, id, type)
    end

    # Stores a custom entry into the room-specific account data
    #
    # @param type [String] the data type to store
    # @param account_data [Hash] the data to store
    def set_account_data(type, account_data)
      client.api.set_room_account_data(client.mxid, id, type, account_data)
      true
    end

    # Changes the room-specific user profile
    #
    # @param display_name [String] the new display name to use in the room
    # @param avatar_url [String,URI] the new avatar URL to use in the room
    # @note the avatar URL should be a mxc:// URI
    def set_user_profile(display_name: nil, avatar_url: nil, reason: nil)
      return nil unless display_name || avatar_url

      data = client.api.get_membership(id, client.mxid)
      raise "Can't set profile if you haven't joined the room" unless data[:membership] == 'join'

      data[:displayname] = display_name unless display_name.nil?
      data[:avatar_url] = avatar_url unless avatar_url.nil?

      client.api.set_membership(id, client.mxid, 'join', reason || 'Updating room profile information', data)
      true
    end

    # Gets the room creation information
    #
    # @return [Response] The content of the m.room.create event
    def creation_info
      # Not caching here, easier to cache the important values separately instead
      client.api.get_room_creation_info(id)
    end

    # Retrieves the type of the room
    #
    # @return ['m.space',String,nil] The type of the room
    def room_type
      # Can't change, so a permanent cache is ok
      return @room_type if @room_type_retrieved || @room_type

      @room_type_retrieved = true
      @room_type ||= creation_info[:type]
    end

    # Retrieves the room version
    #
    # @return [String] The version of the room
    def room_version
      @room_version ||= creation_info[:room_version]
    end

    # Checks if the room is a Matrix Space
    #
    # @return [Boolean,nil] True if the room is a space
    def space?
      room_type == 'm.space'
    rescue MatrixSdk::MatrixForbiddenError, MatrixSdk::MatrixNotFoundError
      nil
    end

    # Returns a list of the room tags
    #
    # @return [Response] A list of the tags and their data, with add and remove methods implemented
    # @example Managing tags
    #   room.tags
    #   # => { :room_tag => { data: false } }
    #   room.tags.add('some_tag', data: true)
    #   # => { :some_tag => { data: true }, :room_tag => { data: false} }
    #   room.tags.remove('room_tag')
    #   # => { :some_tag => { data: true} }
    def tags
      client.api.get_user_tags(client.mxid, id)[:tags].tap do |tag_obj|
        tag_obj.instance_variable_set(:@room, self)
        tag_obj.define_singleton_method(:room) do
          @room
        end
        tag_obj.define_singleton_method(:add) do |tag, **data|
          @room.add_tag(tag.to_s.to_sym, **data)
          self[tag.to_s.to_sym] = data
          self
        end
        tag_obj.define_singleton_method(:remove) do |tag|
          @room.remove_tag(tag.to_s.to_sym)
          delete tag.to_s.to_sym
        end
      end
    end

    # Remove a tag from the room
    #
    # @param [String] tag The tag to remove
    def remove_tag(tag)
      client.api.remove_user_tag(client.mxid, id, tag)
      true
    end

    # Add a tag to the room
    #
    # @param [String] tag The tag to add
    # @param [Hash] data The data to assign to the tag
    def add_tag(tag, **data)
      client.api.add_user_tag(client.mxid, id, tag, data)
      true
    end

    #
    # State updates
    #

    # Refreshes the room state caches for name, topic, and aliases
    def reload!
      reload_name!
      reload_topic!
      reload_aliases!
      true
    end
    alias refresh! reload!

    # Sets a new name on the room
    #
    # @param name [String] The new name to set
    def name=(name)
      tinycache_adapter.write(:name, name)
      client.api.set_room_name(id, name)
      name
    end

    # Reloads the name of the room
    #
    # @return [Boolean] if the name was changed or not
    def reload_name!
      clear_name_cache
    end
    alias refresh_name! reload_name!

    # Sets a new topic on the room
    #
    # @param topic [String] The new topic to set
    def topic=(topic)
      tinycache_adapter.write(:topic, topic)
      client.api.set_room_topic(id, topic)
      topic
    end

    # Reloads the topic of the room
    #
    # @return [Boolean] if the topic was changed or not
    def reload_topic!
      clear_topic_cache
    end
    alias refresh_topic! reload_topic!

    # Add an alias to the room
    #
    # @return [Boolean] if the addition was successful or not
    def add_alias(room_alias)
      client.api.set_room_alias(id, room_alias)
      tinycache_adapter.read(:aliases) << room_alias if tinycache_adapter.exist?(:aliases)
      true
    end

    # Reloads the list of aliases by an API query
    #
    # @return [Boolean] if the alias list was updated or not
    # @note The list of aliases is not sorted, ordering changes will result in
    #       alias list updates.
    def reload_aliases!
      clear_aliases_cache
    end
    alias refresh_aliases! reload_aliases!

    # Sets if the room should be invite only or not
    #
    # @param invite_only [Boolean] If it should be invite only or not
    def invite_only=(invite_only)
      self.join_rule = invite_only ? :invite : :public
      invite_only
    end

    # Sets the join rule of the room
    #
    # @param join_rule [:invite,:public] The join rule of the room
    def join_rule=(join_rule)
      client.api.set_room_join_rules(id, join_rule)
      tinycache_adapter.write(:join_rule, join_rule)
      join_rule
    end

    # Sets if guests are allowed in the room
    #
    # @param allow_guests [Boolean] If guests are allowed to join or not
    def allow_guests=(allow_guests)
      self.guest_access = (allow_guests ? :can_join : :forbidden)
      allow_guests
    end

    # Sets the guest access status for the room
    #
    # @param guest_access [:can_join,:forbidden] The new guest access status of the room
    def guest_access=(guest_access)
      client.api.set_room_guest_access(id, guest_access)
      tinycache_adapter.write(:guest_access, guest_access)
      guest_access
    end

    # Sets a new avatar URL for the room
    #
    # @param avatar_url [URI::MXC] The mxc:// URL for the new room avatar
    def avatar_url=(avatar_url)
      avatar_url = URI(avatar_url) unless avatar_url.is_a? URI
      raise ArgumentError, 'Must be a valid MXC URL' unless avatar_url.is_a? URI::MXC

      client.api.set_room_avatar(id, avatar_url)
      tinycache_adapter.write(:avatar_url, avatar_url)
      avatar_url
    end

    # Get the power levels of the room
    #
    # @note The returned power levels are cached for a minute
    # @return [Hash] The current power levels as set for the room
    # @see Protocols::CS#get_power_levels
    def power_levels
      client.api.get_power_levels(id)
    end

    # Gets the power level of a user in the room
    #
    # @param user [User,MXID,String] The user to check the power level for
    # @param use_default [Boolean] Should the user default level be checked if no user-specific one exists
    # @return [Integer,nil] The current power level for the requested user, nil if there's no user specific level
    #   and use_default is false
    def user_powerlevel(user, use_default: true)
      user = user.id if user.is_a? User
      user = MXID.new(user.to_s) unless user.is_a? MXID
      raise ArgumentError, 'Must provide a valid user or MXID' unless user.user?

      level = power_levels.dig(:users, user.to_s.to_sym)
      level = power_levels[:users_default] || 0 if level.nil? && use_default
      level
    end

    # Check if a user is an admin in the room
    #
    # @param user [User,MXID,String] The user to check for admin privileges
    # @param target_level [Integer] The power level that's to be considered as admin privileges
    # @return [Boolean] If the requested user has a power level highe enough to be an admin
    # @see #user_powerlevel
    def admin?(user, target_level: 100)
      level = user_powerlevel(user, use_default: false)
      return false unless level

      level >= target_level
    end

    # Make a user an admin in the room
    #
    # @param user [User,MXID,String] The user to give admin privileges
    # @param level [Integer] The power level to set the user to
    # @see #modify_user_power_levels
    def admin!(user, level: 100)
      return true if admin?(user, target_level: level)

      user = user.id if user.is_a? User
      user = MXID.new(user.to_s) unless user.is_a? MXID
      raise ArgumentError, 'Must provide a valid user or MXID' unless user.user?

      modify_user_power_levels({ user.to_s.to_sym => level })
    end

    # Check if a user is a moderator in the room
    #
    # @param user [User,MXID,String] The user to check for admin privileges
    # @param target_level [Integer] The power level that's to be considered as admin privileges
    # @return [Boolean] If the requested user has a power level highe enough to be an admin
    # @see #user_powerlevel
    def moderator?(user, target_level: 50)
      level = user_powerlevel(user, use_default: false)
      return false unless level

      level >= target_level
    end

    # Make a user a moderator in the room
    #
    # @param user [User,MXID,String] The user to give moderator privileges
    # @param level [Integer] The power level to set the user to
    # @see #modify_user_power_levels
    def moderator!(user, level: 50)
      return true if moderator?(user, target_level: level)

      user = user.id if user.is_a? User
      user = MXID.new(user.to_s) unless user.is_a? MXID
      raise ArgumentError, 'Must provide a valid user or MXID' unless user.user?

      modify_user_power_levels({ user.to_s.to_sym => level })
    end

    # Modifies the power levels of the room
    #
    # @param users [Hash] the user-specific power levels to set or remove
    # @param users_default [Hash] the default user power levels to set
    # @return [Boolean] if the change was successful
    def modify_user_power_levels(users = nil, users_default = nil)
      return false if users.nil? && users_default.nil?

      data = power_levels_without_cache
      tinycache_adapter.write(:power_levels, data)
      data[:users_default] = users_default unless users_default.nil?

      if users
        data[:users] = {} unless data.key? :users
        users.each do |user, level|
          user = user.id if user.is_a? User
          user = MXID.new(user.to_s) unless user.is_a? MXID
          raise ArgumentError, 'Must provide a valid user or MXID' unless user.user?

          if level.nil?
            data[:users].delete(user.to_s.to_sym)
          else
            data[:users][user.to_s.to_sym] = level
          end
        end
      end

      client.api.set_power_levels(id, data)
      true
    end

    # Modifies the required power levels for actions in the room
    #
    # @param events [Hash] the event-specific power levels to change
    # @param params [Hash] other power-level params to change
    # @return [Boolean] if the change was successful
    def modify_required_power_levels(events = nil, params = {})
      return false if events.nil? && (params.nil? || params.empty?)

      data = power_levels_without_cache
      tinycache_adapter.write(:power_levels, data)
      data.merge!(params)
      data.delete_if { |_k, v| v.nil? }

      if events
        data[:events] = {} unless data.key? :events
        data[:events].merge!(events)
        data[:events].delete_if { |_k, v| v.nil? }
      end

      client.api.set_power_levels(id, data)
      true
    end

    private

    def ensure_member(member)
      tinycache_adapter.write(:joined_members, []) unless tinycache_adapter.exist? :joined_members

      members = tinycache_adapter.read(:joined_members) || []
      members << member unless members.any? { |m| m.id == member.id }
    end

    def handle_power_levels(event)
      tinycache_adapter.write(:power_levels, event[:content])
    end

    def handle_room_name(event)
      tinycache_adapter.write(:name, event.dig(*%i[content name]))
    end

    def handle_room_topic(event)
      tinycache_adapter.write(:topic, event.dig(*%i[content topic]))
    end

    def handle_room_guest_access(event)
      tinycache_adapter.write(:guest_access, event.dig(*%i[content guest_access])&.to_sym)
    end

    def handle_room_join_rules(event)
      tinycache_adapter.write(:join_rule, event.dig(*%i[content join_rule])&.to_sym)
    end

    def handle_room_member(event)
      return unless client.cache == :all

      if event.dig(*%i[content membership]) == 'join'
        ensure_member(client.get_user(event[:state_key]).dup.tap do |u|
          u.instance_variable_set(:@display_name, event.dig(*%i[content displayname]))
        end)
      elsif tinycache_adapter.exist? :joined_members
        members = tinycache_adapter.read(:joined_members)
        members.delete_if { |m| m.id == event[:state_key] }
      end
    end

    def handle_room_canonical_alias(event)
      canonical_alias = tinycache_adapter.write(:canonical_alias, event.dig(*%i[content alias]))

      data = tinycache_adapter.read(:aliases) || []
      data << canonical_alias
      data += event.dig(*%i[content alt_aliases]) || []
      tinycache_adapter.write(:aliases, data.uniq.sort)
    end

    def room_handlers?
      client.instance_variable_get(:@room_handlers).key? id
    end

    def ensure_room_handlers
      client.instance_variable_get(:@room_handlers)[id] ||= {
        event: MatrixSdk::EventHandlerArray.new,
        state_event: MatrixSdk::EventHandlerArray.new,
        ephemeral_event: MatrixSdk::EventHandlerArray.new
      }
    end

    INTERNAL_HANDLERS = {
      'm.room.canonical_alias' => :handle_room_canonical_alias,
      'm.room.guest_access' => :handle_room_guest_access,
      'm.room.join_rules' => :handle_room_join_rules,
      'm.room.member' => :handle_room_member,
      'm.room.name' => :handle_room_name,
      'm.room.power_levels' => :handle_power_levels,
      'm.room.topic' => :handle_room_topic
    }.freeze
    def put_event(event)
      ensure_room_handlers[:event].fire(MatrixEvent.new(self, event), event[:type]) if room_handlers?

      @events.push event
      @events.shift if @events.length > @event_history_limit
    end

    def put_ephemeral_event(event)
      return unless room_handlers?

      ensure_room_handlers[:ephemeral_event].fire(MatrixEvent.new(self, event), event[:type])
    end

    def put_state_event(event)
      send(INTERNAL_HANDLERS[event[:type]], event) if INTERNAL_HANDLERS.key? event[:type]

      return unless room_handlers?

      ensure_room_handlers[:state_event].fire(MatrixEvent.new(self, event), event[:type])
    end
  end
end
