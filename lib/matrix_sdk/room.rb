# frozen_string_literal: true

require 'matrix_sdk'

module MatrixSdk
  # A class for tracking the information about a room on Matrix
  class Room
    extend MatrixSdk::Extensions
    include MatrixSdk::Logging

    # @!attribute [rw] canonical_alias
    #   @return [String, nil] the canonical alias of the room
    # @!attribute [rw] event_history_limit
    #   @return [Fixnum] the limit of events to keep in the event log
    attr_accessor :canonical_alias, :event_history_limit
    # @!attribute [r] id
    #   @return [String] the internal ID of the room
    # @!attribute [r] client
    #   @return [Client] the client for the room
    # @!attribute [rw] name
    #   @return [String, nil] the user-provided name of the room
    #   @see reload_name!
    # @!attribute [rw] topic
    #   @return [String, nil] the user-provided topic of the room
    #   @see reload_topic!
    # @!attribute [r] aliases
    #   @return [Array(String)] a list of user-set aliases for the room
    #   @see add_alias
    #   @see reload_alias!
    # @!attribute [rw] join_rule
    #   @return [:invite, :public] the join rule for the room -
    #                    either +:invite+ or +:public+
    # @!attribute [rw] guest_access
    #   @return [:can_join, :forbidden] the guest access for the room -
    #                    either +:can_join+ or +:forbidden+
    # @!attribute [r] members
    #   @return [Array(User)] the members of the room
    #   @see reload_members!
    # @!attribute [r] events
    #   @return [Array(Object)] the last +event_history_limit+ events to arrive in the room
    #   @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-sync
    #        The timeline events are what will end up in here
    attr_reader :id, :client, :topic, :aliases, :members, :events

    # @!attribute [r] on_event
    #   @return [EventHandlerArray] The list of event handlers for all events
    # @!attribute [r] on_state_event
    #   @return [EventHandlerArray] The list of event handlers for only state events
    # @!attribute [r] on_ephemeral_event
    #   @return [EventHandlerArray] The list of event handlers for only ephemeral events
    events :event, :state_event, :ephemeral_event
    # @!method inspect
    #   An inspect method that skips a handful of instance variables to avoid
    #   flooding the terminal with debug data.
    #   @return [String] a regular inspect string without the data for some variables
    ignore_inspect :client, :members, :events, :prev_batch, :logger,
                   :on_event, :on_state_event, :on_ephemeral_event

    alias room_id id

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
    # @option data [:invite,:public] :join_rule The join rule for the room
    # @option data [:can_join,:forbidden] :guest_access The guest access setting for the room
    # @option data [Boolean] :world_readable If the room is readable by the entire world
    # @option data [Array(User)] :members The list of joined members
    # @option data [Array(Object)] :events The list of current events in the room
    # @option data [Boolean] :members_loaded If the list of members is already loaded
    # @option data [Integer] :event_history_limit (10) The limit of events to store for the room
    # @option data [String,URI] :avatar_url The avatar URL for the room
    # @option data [String] :prev_batch The previous batch token for backfill
    def initialize(client, room_id, data = {})
      raise ArgumentError, 'Must be given a Client instance' unless client.is_a? Client
      raise ArgumentError, 'room_id must be a valid Room ID' unless room_id.is_a?(MXID) && room_id.room_id?

      event_initialize

      @name = nil
      @topic = nil
      @canonical_alias = nil
      @aliases = []
      @join_rule = nil
      @guest_access = nil
      @world_readable = nil
      @members = []
      @events = []
      @members_loaded = false
      @event_history_limit = 10
      @avatar_url = nil

      @prev_batch = nil

      data.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end

      @client = client
      @id = room_id.to_s

      @name_checked = Time.new(0)

      logger.debug "Created room #{room_id}"
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

    # Populates and returns the #members array
    def joined_members
      return members if @members_loaded && !members.empty?

      client.api.get_room_joined_members(id)[:joined].each do |mxid, data|
        ensure_member(User.new(client, mxid.to_s,
                               display_name: data.fetch(:display_name, nil),
                               avatar_url: data.fetch(:avatar_url, nil)))
      end
      @members_loaded = true
      members
    end

    def name
      return @name if Time.now - @name_checked < 10

      @name_checked = Time.now
      @name ||= client.api.get_room_name(id)
    rescue MatrixNotFoundError
      # No room name has been specified
      nil
    end

    # Gets the avatar url of the room - if any
    def avatar_url
      @avatar_url ||= client.api.get_room_avatar(id).url
    rescue MatrixNotFoundError
      # No avatar has been set
      nil
    end

    def guest_access
      @guest_access ||= client.api.get_room_guest_access(id).guest_access.to_sym
    end

    def join_rule
      @join_rule ||= client.api.get_room_join_rules(id).join_rule.to_sym
    end

    # Checks if +guest_access+ is set to +:can_join+
    def guest_access?
      guest_access == :can_join
    end

    # Checks if +join_rule+ is set to +:invite+
    def invite_only?
      join_rule == :invite
    end

    #
    # Message handling
    #

    # Sends a plain-text message to the room
    # @param text [String] the message to send
    def send_text(text)
      client.api.send_message(id, text)
    end

    # Sends a custom HTML message to the room
    # @param html [String] the HTML message to send
    # @param body [String,nil] a plain-text representation of the object
    #        (Will default to the HTML with tags stripped away)
    # @param msg_type [String] A message type for the message
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-room-message-msgtypes
    #      Possible message types as defined by the spec
    def send_html(html, body = nil, msg_type = 'm.text')
      content = {
        body: body || html.gsub(/<\/?[^>]*>/, ''),
        msgtype: msg_type,
        format: 'org.matrix.custom.html',
        formatted_body: html
      }

      client.api.send_message_event(id, 'm.room.message', content)
    end

    # Sends an emote (/me) message to the room
    # @param text [String] the emote to send
    def send_emote(text)
      client.api.send_emote(id, text)
    end

    # Sends a link to a generic file to the room
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
    # @param text [String] the notice to send
    def send_notice(text)
      client.api.send_notice(id, text)
    end

    # Sends a link to an image to the room
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
    # @param geo_uri [String,URI] the geo-URL (e.g. geo:<coords>) of the location
    # @param name [String] the name of the location
    # @param thumbnail_url [String,URI] the URL to a thumbnail image of the location
    # @param thumbnail_info [Hash] a ThumbnailInfo for the location thumbnail
    # @note The thumbnail URL should be of the 'mxc://' schema
    def send_location(geo_uri, name, thumbnail_url = nil, thumbnail_info = {})
      client.api.send_location(id, geo_uri, name, thumbnail_url: thumbnail_url, thumbnail_info: thumbnail_info)
    end

    # Sends a link to a video to the room
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

    # Redacts a message from the room
    # @param event_id [String] the ID of the event to redact
    # @param reason [String,nil] the reason for the redaction
    def redact_message(event_id, reason = nil)
      client.api.redact_event(id, event_id, reason: reason)
      true
    end

    # Backfills messages into the room history
    # @param reverse [Boolean] whether to fill messages in reverse or not
    # @param limit [Integer] the maximum number of messages to backfill
    # @note This will trigger the `on_event` events as messages are added
    def backfill_messages(reverse = false, limit = 10)
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
    # @param user_id [String,User] the MXID of the user
    # @return [Boolean] wether the action succeeded
    def invite_user(user_id)
      user_id = user_id.id if user_id.is_a? MatrixSdk::User
      client.api.invite_user(id, user_id)
      true
    end

    # Kicks a user from the room
    # @param user_id [String,User] the MXID of the user
    # @param reason [String] the reason for the kick
    # @return [Boolean] wether the action succeeded
    def kick_user(user_id, reason = '')
      user_id = user_id.id if user_id.is_a? MatrixSdk::User
      client.api.kick_user(id, user_id, reason: reason)
      true
    end

    # Bans a user from the room
    # @param user_id [String,User] the MXID of the user
    # @param reason [String] the reason for the ban
    # @return [Boolean] wether the action succeeded
    def ban_user(user_id, reason = '')
      user_id = user_id.id if user_id.is_a? MatrixSdk::User
      client.api.ban_user(id, user_id, reason: reason)
      true
    end

    # Unbans a user from the room
    # @param user_id [String,User] the MXID of the user
    # @return [Boolean] wether the action succeeded
    def unban_user(user_id)
      user_id = user_id.id if user_id.is_a? MatrixSdk::User
      client.api.unban_user(id, user_id)
      true
    end

    # Requests to be removed from the room
    # @return [Boolean] wether the request succeeded
    def leave
      client.api.leave_room(id)
      client.instance_variable_get(:@rooms).delete id
      true
    end

    # Retrieves a custom entry from the room-specific account data
    # @param type [String] the data type to retrieve
    # @return [Hash] the data that was stored under the given type
    def get_account_data(type)
      client.api.get_room_account_data(client.mxid, id, type)
    end

    # Stores a custom entry into the room-specific account data
    # @param type [String] the data type to store
    # @param account_data [Hash] the data to store
    def set_account_data(type, account_data)
      client.api.set_room_account_data(client.mxid, id, type, account_data)
      true
    end

    # Changes the room-specific user profile
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

    # Returns a list of the room tags
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
          @room.add_tag(tag.to_s.to_sym, data)
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
    # @param [String] tag The tag to remove
    def remove_tag(tag)
      client.api.remove_user_tag(client.mxid, id, tag)
      true
    end

    # Add a tag to the room
    # @param [String] tag The tag to add
    # @param [Hash] data The data to assign to the tag
    def add_tag(tag, **data)
      client.api.add_user_tag(client.mxid, id, tag, data)
      true
    end

    #
    # State updates
    #

    def reload!
      reload_name!
      reload_topic!
      reload_aliases!
      true
    end
    alias refresh! reload!

    def name=(name)
      client.api.set_room_name(id, name)
      @name = name
    end

    # Reloads the name of the room
    # @return [Boolean] if the name was changed or not
    def reload_name!
      data = begin
               client.api.get_room_name(id)
             rescue MatrixNotFoundError
               nil
             end
      changed = data[:name] != @name
      @name = data[:name] if changed
      changed
    end
    alias refresh_name! reload_name!

    def topic=(topic)
      client.api.set_room_topic(id, topic)
      @topic = topic
    end

    # Reloads the topic of the room
    # @return [Boolean] if the topic was changed or not
    def reload_topic!
      data = begin
               client.api.get_room_topic(id)
             rescue MatrixNotFoundError
               nil
             end
      changed = data[:topic] != @topic
      @topic = data[:topic] if changed
      changed
    end
    alias refresh_topic! reload_topic!

    # Add an alias to the room
    # @return [Boolean] if the addition was successful or not
    def add_alias(room_alias)
      client.api.set_room_alias(id, room_alias)
      @aliases << room_alias
      true
    end

    # Reloads the list of aliases by an API query
    # @return [Boolean] if the alias list was updated or not
    # @note The list of aliases is not sorted, ordering changes will result in
    #       alias list updates.
    def reload_aliases!
      begin
        new_aliases = client.api.get_room_aliases(id).aliases
      rescue MatrixNotFoundError
        data = client.api.get_room_state_all(id)
        new_aliases = data.select { |chunk| chunk[:type] == 'm.room.aliases' && chunk.key?(:content) && chunk[:content].key?(:aliases) }
                          .map { |chunk| chunk[:content][:aliases] }
                          .flatten
                          .compact
      end

      return false if new_aliases.nil?

      changed = new_aliases != aliases
      @aliases = new_aliases if changed
      changed
    end
    alias refresh_aliases! reload_aliases!

    def invite_only=(invite_only)
      self.join_rule = invite_only ? :invite : :public
      @join_rule == :invite
    end

    def join_rule=(join_rule)
      client.api.set_join_rule(id, join_rule)
      @join_rule = join_rule
    end

    def allow_guests=(allow_guests)
      self.guest_access = (allow_guests ? :can_join : :forbidden)
      @guest_access == :can_join
    end

    def guest_access=(guest_access)
      client.api.set_guest_access(id, guest_access)
      @guest_access = guest_access
    end

    def avatar_url=(avatar_url)
      avatar_url = URI(avatar_url) unless avatar_url.is_a? URI
      raise ArgumentError, 'Must be a valid MXC URL' unless avatar_url.is_a? URI::MATRIX

      client.api.set_room_avatar(id, avatar_url)
      @avatar_url = avatar_url
    end

    # Modifies the power levels of the room
    # @param users [Hash] the user-specific power levels to set or remove
    # @param users_default [Hash] the default user power levels to set
    # @return [Boolean] if the change was successful
    def modify_user_power_levels(users = nil, users_default = nil)
      return false if users.nil? && users_default.nil?

      data = client.api.get_power_levels(id)
      data[:users_default] = users_default unless users_default.nil?

      if users
        data[:users] = {} unless data.key? :users
        data[:users].merge!(users)
        data[:users].delete_if { |_k, v| v.nil? }
      end

      client.api.set_power_levels(id, data)
      true
    end

    # Modifies the required power levels for actions in the room
    # @param events [Hash] the event-specific power levels to change
    # @param params [Hash] other power-level params to change
    # @return [Boolean] if the change was successful
    def modify_required_power_levels(events = nil, params = {})
      return false if events.nil? && (params.nil? || params.empty?)

      data = client.api.get_power_levels(id)
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
      members << member unless members.any? { |m| m.id == member.id }
    end

    def put_event(event)
      @events.push event
      @events.shift if @events.length > @event_history_limit

      fire_event MatrixEvent.new(self, event)
    end

    def put_ephemeral_event(event)
      fire_ephemeral_event MatrixEvent.new(self, event)
    end
  end
end
