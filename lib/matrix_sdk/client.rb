# frozen_string_literal: true

require 'matrix_sdk'
require 'matrix_sdk/util/events'

require 'English'
require 'forwardable'

module MatrixSdk
  class Client
    extend MatrixSdk::Extensions
    include MatrixSdk::Logging
    extend Forwardable

    # @!attribute api [r] The underlying API connection
    #   @return [Api] The underlying API connection
    # @!attribute next_batch [r] The batch token for a running sync
    #   @return [String] The opaque batch token
    # @!attribute cache [rw] The cache level
    #   @return [:all,:some,:none] The level of caching to do
    # @!attribute sync_filter [rw] The global sync filter
    #   @return [Hash,String] A filter definition, either as defined by the
    #           Matrix spec, or as an identifier returned by a filter creation request
    attr_reader :api, :next_batch
    attr_accessor :cache, :sync_filter, :sync_token

    events :error, :event, :presence_event, :invite_event, :leave_event, :ephemeral_event, :state_event
    ignore_inspect :api,
                   :on_event, :on_presence_event, :on_invite_event, :on_leave_event, :on_ephemeral_event

    def_delegators :@api,
                   :access_token, :access_token=, :device_id, :device_id=, :homeserver, :homeserver=,
                   :validate_certificate, :validate_certificate=

    # Create a new client instance from only a Matrix HS domain
    #
    # This will use the well-known delegation lookup to find the correct client URL
    #
    # @note This method will not verify that the created client has a valid connection,
    #       it will only perform the necessary lookups to build a connection URL.
    # @return [Client] The new client instance
    # @param domain [String] The domain name to look up
    # @param params [Hash] Additional parameters to pass along to {Api.new_for_domain} as well as {initialize}
    # @see Api.new_for_domain
    # @see #initialize
    def self.new_for_domain(domain, **params)
      api = MatrixSdk::Api.new_for_domain(domain, keep_wellknown: true)
      return new(api, params) unless api.well_known&.key?('m.identity_server')

      identity_server = MatrixSdk::Api.new(api.well_known['m.identity_server']['base_url'], protocols: %i[IS])
      new(api, params.merge(identity_server: identity_server))
    end

    # @param hs_url [String,URI,Api] The URL to the Matrix homeserver, without the /_matrix/ part, or an existing Api instance
    # @param client_cache [:all,:some,:none] (:all) How much data should be cached in the client
    # @param params [Hash] Additional parameters on creation
    # @option params [String,MXID] :user_id The user ID of the logged-in user
    # @option params [Integer] :sync_filter_limit (20) Limit of timeline entries in syncs
    # @see MatrixSdk::Api.new for additional usable params
    def initialize(hs_url, client_cache: :all, **params)
      event_initialize

      params[:user_id] ||= params[:mxid] if params[:mxid]

      if hs_url.is_a? Api
        @api = hs_url
        params.each do |k, v|
          api.instance_variable_set("@#{k}", v) if api.instance_variable_defined? "@#{k}"
        end
      else
        @api = Api.new hs_url, **params
      end

      @cache = client_cache
      @identity_server = nil
      @mxid = nil

      @sync_token = nil
      @sync_thread = nil
      @sync_filter = { room: { timeline: { limit: params.fetch(:sync_filter_limit, 20) }, state: { lazy_load_members: true } } }

      @next_batch = nil

      @bad_sync_timeout_limit = 60 * 60

      params.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end

      @rooms = {}
      @room_handlers = {}
      @users = {}
      @should_listen = false

      raise ArgumentError, 'Cache value must be one of of [:all, :some, :none]' unless %i[all some none].include? @cache

      return unless params[:user_id]

      @mxid = params[:user_id]
    end

    # Gets the currently logged in user's MXID
    #
    # @return [MXID] The MXID of the current user
    def mxid
      @mxid ||= MXID.new api.whoami?[:user_id] if api&.access_token
      @mxid
    end

    alias user_id mxid

    # Gets the current user presence status object
    #
    # @return [Response] The user presence
    # @see User#presence
    # @see Protocols::CS#get_presence_status
    def presence
      api.get_presence_status(mxid).tap { |h| h.delete :user_id }
    end

    # Sets the current user's presence status
    #
    # @param status [:online,:offline,:unavailable] The new status to use
    # @param message [String] A custom status message to set
    # @see User#presence=
    # @see Protocols::CS#set_presence_status
    def set_presence(status, message: nil)
      raise ArgumentError, 'Presence must be one of :online, :offline, :unavailable' unless %i[online offline unavailable].include?(status)

      api.set_presence_status(mxid, status, message: message)
    end

    # Gets a list of all the public rooms on the connected HS
    #
    # @note This will try to list all public rooms on the HS, and may take a while on larger instances
    # @return [Array[Room]] The public rooms
    def public_rooms
      rooms = []
      since = nil
      loop do
        data = api.get_public_rooms since: since

        data[:chunk].each do |chunk|
          rooms << Room.new(self, chunk[:room_id],
                            name: chunk[:name], topic: chunk[:topic], aliases: chunk[:aliases],
                            canonical_alias: chunk[:canonical_alias], avatar_url: chunk[:avatar_url],
                            join_rule: :public, world_readable: chunk[:world_readable]).tap do |r|
            r.instance_variable_set :@guest_access, chunk[:guest_can_join] ? :can_join : :forbidden
          end
        end

        break if data[:next_batch].nil?

        since = data.next_batch
      end

      rooms
    end

    # Gets a list of all direct chat rooms (1:1 chats / direct message chats) for the currenct user
    #
    # @return [Hash[String,Array[String]]] A mapping of MXIDs to a list of direct rooms with that user
    def direct_rooms
      api.get_account_data(mxid, 'm.direct').transform_keys(&:to_s)
    end

    # Gets a direct message room for the given user if one exists
    #
    # @note Will return the oldest room if multiple exist
    # @return [Room,nil] A direct message room if one exists
    def direct_room(mxid)
      mxid = MatrixSdk::MXID.new mxid.to_s unless mxid.is_a? MatrixSdk::MXID
      raise ArgumentError, 'Must be a valid user ID' unless mxid.user?

      room_id = direct_rooms[mxid.to_s]&.first
      ensure_room room_id if room_id
    end

    # Gets a list of all relevant rooms, either the ones currently handled by
    # the client, or the list of currently joined ones if no rooms are handled
    #
    # @return [Array[Room]] All the currently handled rooms
    # @note This will always return the empty array if the cache level is set
    #       to :none
    def rooms
      if @rooms.empty? && cache != :none
        api.get_joined_rooms.joined_rooms.each do |id|
          ensure_room(id)
        end
      end

      @rooms.values
    end

    # Get a list of all joined Matrix Spaces
    #
    # @return [Array[Room]] All the currently joined Spaces
    def spaces
      rooms = if cache == :none
                api.get_joined_rooms.joined_rooms.map { |id| Room.new(self, id) }
              else
                self.rooms
              end

      rooms.select(&:space?)
    end

    # Refresh the list of currently handled rooms, replacing it with the user's
    # currently joined rooms.
    #
    # @note This will be a no-op if the cache level is set to :none
    # @return [Boolean] If the refresh succeeds
    def reload_rooms!
      return true if cache == :none

      @rooms.clear
      api.get_joined_rooms.joined_rooms.each do |id|
        r = ensure_room(id)
        r.reload!
      end

      true
    end
    alias refresh_rooms! reload_rooms!
    alias reload_spaces! reload_rooms!

    # Register - and log in - on the connected HS as a guest
    #
    # @note This feature is not commonly supported by many HSes
    def register_as_guest
      data = api.register(kind: :guest)
      post_authentication(data)
    end

    # Register a new user account on the connected HS
    #
    # This will also trigger an initial sync unless no_sync is set
    #
    # @note This method will currently always use auth type 'm.login.dummy'
    # @param username [String] The new user's name
    # @param password [String] The new user's password
    # @param params [Hash] Additional options
    # @option params [Boolean] :no_sync Skip the initial sync on registering
    # @option params [Boolean] :allow_sync_retry Allow sync to retry on failure
    def register_with_password(username, password, **params)
      username = username.to_s unless username.is_a?(String)
      password = password.to_s unless password.is_a?(String)

      raise ArgumentError, "Username can't be nil or empty" if username.nil? || username.empty?
      raise ArgumentError, "Password can't be nil or empty" if password.nil? || username.empty?

      data = api.register(auth: { type: 'm.login.dummy' }, username: username, password: password)
      post_authentication(data)

      return if params[:no_sync]

      sync full_state: true,
           allow_sync_retry: params.fetch(:allow_sync_retry, nil)
    end

    # Logs in as a user on the connected HS
    #
    # This will also trigger an initial sync unless no_sync is set
    #
    # @param username [String] The username of the user
    # @param password [String] The password of the user
    # @param sync_timeout [Numeric] The timeout of the initial sync on login
    # @param full_state [Boolean] Should the initial sync retrieve full state
    # @param params [Hash] Additional options
    # @option params [Boolean] :no_sync Skip the initial sync on registering
    # @option params [Boolean] :allow_sync_retry Allow sync to retry on failure
    def login(username, password, sync_timeout: 15, full_state: false, **params)
      username = username.to_s unless username.is_a?(String)
      password = password.to_s unless password.is_a?(String)

      raise ArgumentError, "Username can't be nil or empty" if username.nil? || username.empty?
      raise ArgumentError, "Password can't be nil or empty" if password.nil? || password.empty?

      data = api.login(user: username, password: password)
      post_authentication(data)

      return if params[:no_sync]

      sync timeout: sync_timeout,
           full_state: full_state,
           allow_sync_retry: params.fetch(:allow_sync_retry, nil)
    end

    # Logs in as a user on the connected HS
    #
    # This will also trigger an initial sync unless no_sync is set
    #
    # @param username [String] The username of the user
    # @param token [String] The token to log in with
    # @param sync_timeout [Numeric] The timeout of the initial sync on login
    # @param full_state [Boolean] Should the initial sync retrieve full state
    # @param params [Hash] Additional options
    # @option params [Boolean] :no_sync Skip the initial sync on registering
    # @option params [Boolean] :allow_sync_retry Allow sync to retry on failure
    def login_with_token(username, token, sync_timeout: 15, full_state: false, **params)
      username = username.to_s unless username.is_a?(String)
      token = token.to_s unless token.is_a?(String)

      raise ArgumentError, "Username can't be nil or empty" if username.nil? || username.empty?
      raise ArgumentError, "Token can't be nil or empty" if token.nil? || token.empty?

      data = api.login(user: username, token: token, type: 'm.login.token')
      post_authentication(data)

      return if params[:no_sync]

      sync timeout: sync_timeout,
           full_state: full_state,
           allow_sync_retry: params.fetch(:allow_sync_retry, nil)
    end

    # Logs out of the current session
    def logout
      api.logout
      @api.access_token = nil
      @mxid = nil
    end

    # Check if there's a currently logged in session
    #
    # @note This will not check if the session is valid, only if it exists
    # @return [Boolean] If there's a current session
    def logged_in?
      !@api.access_token.nil?
    end

    # Retrieve a list of all registered third-party IDs for the current user
    #
    # @return [Response] A response hash containing the key :threepids
    # @see Protocols::CS#get_3pids
    def registered_3pids
      data = api.get_3pids
      data.threepids.each do |obj|
        obj.instance_eval do
          def added_at
            Time.at(self[:added_at] / 1000)
          end

          def validated_at
            return unless validated?

            Time.at(self[:validated_at] / 1000)
          end

          def validated?
            key? :validated_at
          end

          def to_s
            "#{self[:medium]}:#{self[:address]}"
          end

          def inspect
            "#<MatrixSdk::Response 3pid=#{to_s.inspect} added_at=\"#{added_at}\"#{validated? ? " validated_at=\"#{validated_at}\"" : ''}>"
          end
        end
      end
      data
    end

    # Creates a new room
    #
    # @example Creating a room with an alias
    #   client.create_room('myroom')
    #   #<MatrixSdk::Room ... >
    #
    # @param room_alias [String] A default alias to set on the room, should only be the localpart
    # @return [Room] The resulting room
    # @see Protocols::CS#create_room
    def create_room(room_alias = nil, **params)
      data = api.create_room(**params.merge(room_alias: room_alias))
      ensure_room(data.room_id)
    end

    # Joins an already created room
    #
    # @param room_id_or_alias [String,MXID] A room alias (#room:example.com) or a room ID (!id:example.com)
    # @param server_name [Array[String]] A list of servers to attempt the join through, required for IDs
    # @return [Room] The resulting room
    # @see Protocols::CS#join_room
    def join_room(room_id_or_alias, server_name: [])
      server_name = [server_name] unless server_name.is_a? Array
      data = api.join_room(room_id_or_alias, server_name: server_name)
      ensure_room(data.fetch(:room_id, room_id_or_alias))
    end

    # Find a room in the locally cached list of rooms that the current user is part of
    #
    # @param room_id_or_alias [String,MXID] A room ID or alias
    # @param only_canonical [Boolean] Only match alias against the canonical alias
    # @return [Room] The found room
    # @return [nil] If no room was found
    def find_room(room_id_or_alias, only_canonical: true)
      room_id_or_alias = MXID.new(room_id_or_alias.to_s) unless room_id_or_alias.is_a? MXID
      raise ArgumentError, 'Must be a room id or alias' unless room_id_or_alias.room?

      return @rooms.fetch(room_id_or_alias.to_s, nil) if room_id_or_alias.room_id?

      room = @rooms.values.find { |r| r.aliases.include? room_id_or_alias.to_s }
      return room if only_canonical

      room || @rooms.values.find { |r| r.aliases(canonical_only: false).include? room_id_or_alias.to_s }
    end

    # Get a User instance from a MXID
    #
    # @param user_id [String,MXID,:self] The MXID to look up, will also accept :self in order to get the currently logged-in user
    # @return [User] The User instance for the specified user
    # @raise [ArgumentError] If the input isn't a valid user ID
    # @note The method doesn't perform any existence checking, so the returned User object may point to a non-existent user
    def get_user(user_id)
      user_id = mxid if user_id == :self

      user_id = MXID.new user_id.to_s unless user_id.is_a? MXID
      raise ArgumentError, 'Must be a User ID' unless user_id.user?

      # To still use regular string storage in the hash itself
      user_id = user_id.to_s

      if cache == :all
        @users[user_id] ||= User.new(self, user_id)
      else
        User.new(self, user_id)
      end
    end

    # Remove a room alias
    #
    # @param room_alias [String,MXID] The room alias to remove
    # @see Protocols::CS#remove_room_alias
    def remove_room_alias(room_alias)
      room_alias = MXID.new room_alias.to_s unless room_alias.is_a? MXID
      raise ArgumentError, 'Must be a room alias' unless room_alias.room_alias?

      api.remove_room_alias(room_alias)
    end

    # Upload a piece of data to the media repo
    #
    # @return [URI::MXC] A Matrix content (mxc://) URL pointing to the uploaded data
    # @param content [String] The data to upload
    # @param content_type [String] The MIME type of the data
    # @see Protocols::CS#media_upload
    def upload(content, content_type)
      data = api.media_upload(content, content_type)
      return URI(data[:content_uri]) if data.key? :content_uri

      raise MatrixUnexpectedResponseError, 'Upload succeeded, but no media URI returned'
    end

    # Starts a background thread that will listen to new events
    #
    # @see sync For What parameters are accepted
    def start_listener_thread(**params)
      return if listening?

      @should_listen = true
      if api.protocol?(:MSC) && api.msc2108?
        params[:filter] = sync_filter unless params.key? :filter
        params[:filter] = params[:filter].to_json unless params[:filter].nil? || params[:filter].is_a?(String)
        params[:since] = @next_batch if @next_batch

        errors = 0
        thread, cancel_token = api.msc2108_sync_sse(params) do |data, event:, id:|
          @next_batch = id if id
          case event.to_sym
          when :sync
            handle_sync_response(data)
            errors = 0
          when :sync_error
            logger.error "SSE Sync error received; #{data.type}: #{data.message}"
            errors += 1

            # TODO: Allow configuring
            raise 'Aborting due to excessive errors' if errors >= 5
          end
        end

        @should_listen = cancel_token
      else
        thread = Thread.new { listen_forever(**params) }
      end
      @sync_thread = thread
      thread.run
    end

    # Stops the running background thread if one is active
    def stop_listener_thread
      return unless @sync_thread

      if @should_listen.is_a? Hash
        @should_listen[:run] = false
      else
        @should_listen = false
      end
      if @sync_thread.alive?
        ret = @sync_thread.join(2)
        @sync_thread.kill unless ret
      end
      @sync_thread = nil
    end

    # Check if there's a thread listening for events
    def listening?
      @sync_thread&.alive? == true
    end

    # Run a message sync round, triggering events as necessary
    #
    # @param skip_store_batch [Boolean] Should this sync skip storing the returned next_batch token,
    #        doing this would mean the next sync re-runs from the same point. Useful with use of filters.
    # @param params [Hash] Additional options
    # @option params [String,Hash] :filter (#sync_filter) A filter to use for this sync
    # @option params [Numeric] :timeout (30) A timeout value in seconds for the sync request
    # @option params [Numeric] :allow_sync_retry (0) The number of retries allowed for this sync request
    # @option params [String] :since An override of the "since" token to provide to the sync request
    # @see Protocols::CS#sync
    def sync(skip_store_batch: false, **params)
      extra_params = {
        filter: sync_filter,
        timeout: 30
      }
      extra_params[:since] = @next_batch unless @next_batch.nil?
      extra_params.merge!(params)
      extra_params[:filter] = extra_params[:filter].to_json unless extra_params[:filter].is_a? String

      attempts = 0
      data = loop do
        break api.sync(**extra_params)
      rescue MatrixSdk::MatrixTimeoutError => e
        raise e if (attempts += 1) >= params.fetch(:allow_sync_retry, 0)
      end

      @next_batch = data[:next_batch] unless skip_store_batch

      handle_sync_response(data)
      true
    end

    alias listen_for_events sync

    # Ensures that a room exists in the cache
    #
    # @param room_id [String,MXID] The room ID to ensure
    # @return [Room] The room object for the requested room
    def ensure_room(room_id)
      room_id = MXID.new room_id.to_s unless room_id.is_a? MXID
      raise ArgumentError, 'Must be a room ID' unless room_id.room_id?

      room_id = room_id.to_s
      ret = @rooms.fetch(room_id) do
        room = Room.new(self, room_id)
        @rooms[room_id] = room unless cache == :none
        room
      end
      # Need to figure out a way to handle multiple types
      ret = @rooms[room_id] = ret.to_space if ret.instance_variable_get :@room_type
      ret
    end

    def listen_forever(timeout: 30, bad_sync_timeout: 5, sync_interval: 0, **params)
      orig_bad_sync_timeout = bad_sync_timeout + 0
      while @should_listen
        begin
          sync(**params.merge(timeout: timeout))

          bad_sync_timeout = orig_bad_sync_timeout
          sleep(sync_interval) if sync_interval.positive?
        rescue MatrixRequestError => e
          logger.warn("A #{e.class} occurred during sync")
          if e.httpstatus >= 500
            logger.warn("Serverside error, retrying in #{bad_sync_timeout} seconds...")
            sleep(bad_sync_timeout) if bad_sync_timeout.positive? # rubocop:disable Metrics/BlockNesting
            bad_sync_timeout = [bad_sync_timeout * 2, @bad_sync_timeout_limit].min
          end
        end
      end
    rescue StandardError => e
      logger.error "Unhandled #{e.class} raised in background listener"
      logger.error [e.message, *e.backtrace].join($RS)
      fire_error(ErrorEvent.new(e, :listener_thread))
    end

    private

    def post_authentication(data)
      @mxid = MXID.new data[:user_id]
      @api.access_token = data[:access_token]
      @api.device_id = data[:device_id]
      @api.homeserver = data[:home_server]
      access_token
    end

    def handle_state(room_id, state_event)
      return unless state_event.key? :type

      on_state_event.fire(MatrixEvent.new(self, state_event), state_event[:type])

      room = ensure_room(room_id)
      room.send :put_state_event, state_event
    end

    def handle_sync_response(data)
      data.dig(:presence, :events)&.each do |presence_update|
        fire_presence_event(MatrixEvent.new(self, presence_update))
      end

      data.dig(:rooms, :invite)&.each do |room_id, invite|
        invite[:room_id] = room_id.to_s
        fire_invite_event(MatrixEvent.new(self, invite), room_id.to_s)
      end

      data.dig(:rooms, :leave)&.each do |room_id, left|
        left[:room_id] = room_id.to_s
        fire_leave_event(MatrixEvent.new(self, left), room_id.to_s)
      end

      data.dig(:rooms, :join)&.each do |room_id, join|
        room = ensure_room(room_id)
        room.instance_variable_set '@prev_batch', join.dig(:timeline, :prev_batch)
        room.instance_variable_set :@members_loaded, true unless sync_filter.fetch(:room, {}).fetch(:state, {}).fetch(:lazy_load_members, false)

        join.dig(:state, :events)&.each do |event|
          event[:room_id] = room_id.to_s
          handle_state(room_id, event)
        end

        join.dig(:timeline, :events)&.each do |event|
          event[:room_id] = room_id.to_s
          # Avoid sending two identical state events if it's both in state and timeline
          if event.key?(:state_key)
            state_event = join.dig(:state, :events)&.find { |ev| ev[:event_id] == event[:event_id] }

            handle_state(room_id, event) unless event == state_event
          end
          room.send :put_event, event

          fire_event(MatrixEvent.new(self, event), event[:type])
        end

        join.dig(:ephemeral, :events)&.each do |event|
          event[:room_id] = room_id.to_s
          room.send :put_ephemeral_event, event

          fire_ephemeral_event(MatrixEvent.new(self, event), event[:type])
        end
      end

      unless cache == :none
        @rooms.each do |_id, room|
          # Clean up old cache data after every sync
          # TODO Run this in a thread?
          room.tinycache_adapter.cleanup
        end
      end

      nil
    end
  end
end
