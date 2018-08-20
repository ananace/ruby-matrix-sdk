require 'matrix_sdk'

require 'forwardable'

module MatrixSdk
  class Client
    extend Forwardable

    attr_reader :api
    attr_writer :mxid
    attr_accessor :cache, :sync_filter

    events :event, :presence_event, :invite_event, :left_event, :ephemeral_event
    ignore_inspect :api,
                   :on_event, :on_presence_event, :on_invite_event, :on_left_event, :on_ephemeral_event

    alias user_id= mxid=

    def_delegators :@api,
                   :access_token, :access_token=, :device_id, :device_id=, :homeserver, :homeserver=,
                   :validate_certificate, :validate_certificate=

    def initialize(hs_url, params = {})
      event_initialize

      params[:user_id] ||= params[:mxid] if params[:mxid]

      if hs_url.is_a? Api
        @api = hs_url
        params.each do |k, v|
          api.instance_variable_set("@#{k}", v) if api.instance_variable_defined? "@#{k}"
        end
      else
        @api = Api.new hs_url, params
      end

      @rooms = {}
      @users = {}
      @cache = params.fetch(:client_cache, :all)

      @sync_token = nil
      @sync_thread = nil
      @sync_filter = { room: { timeline: { limit: params.fetch(:sync_filter_limit, 20) } } }

      @should_listen = false
      @next_batch = nil

      @bad_sync_timeout_limit = 60 * 60

      params.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end

      raise ArgumentError, 'Cache value must be one of of [:all, :some, :none]' unless %i[all some none].include? @cache

      return unless params[:user_id]
      @mxid = params[:user_id]
    end

    def logger
      @logger ||= Logging.logger[self]
    end

    def mxid
      @mxid ||= begin
        api.whoami?[:user_id] if api && api.access_token
      end
    end

    alias user_id mxid

    def rooms
      @rooms.values
    end

    def register_as_guest
      data = api.register(kind: :guest)
      post_authentication(data)
    end

    def register_with_password(username, password)
      username = username.to_s unless username.is_a?(String)
      password = password.to_s unless password.is_a?(String)

      raise ArgumentError, "Username can't be nil or empty" if username.nil? || username.empty?
      raise ArgumentError, "Password can't be nil or empty" if password.nil? || username.empty?

      data = api.register(auth: { type: 'm.login.dummy' }, username: username, password: password)
      post_authentication(data)
    end

    def login(username, password, params = {})
      username = username.to_s unless username.is_a?(String)
      password = password.to_s unless password.is_a?(String)

      raise ArgumentError, "Username can't be nil or empty" if username.nil? || username.empty?
      raise ArgumentError, "Password can't be nil or empty" if password.nil? || password.empty?

      data = api.login(user: username, password: password)
      post_authentication(data)

      return if params[:no_sync]

      sync timeout: params.fetch(:sync_timeout, 15),
           full_state: params.fetch(:full_state, false),
           allow_sync_retry: params.fetch(:allow_sync_retry, nil)
    end

    def login_with_token(username, token, params = {})
      username = username.to_s unless username.is_a?(String)
      token = token.to_s unless token.is_a?(String)

      raise ArgumentError, "Username can't be nil or empty" if username.nil? || username.empty?
      raise ArgumentError, "Token can't be nil or empty" if token.nil? || token.empty?

      data = api.login(user: username, token: token, type: 'm.login.token')
      post_authentication(data)

      return if params[:no_sync]

      sync timeout: params.fetch(:sync_timeout, 15),
           full_state: params.fetch(:full_state, false),
           allow_sync_retry: params.fetch(:allow_sync_retry, nil)
    end

    def logout
      api.logout
      @api.access_token = nil
      @mxid = nil
    end

    def logged_in?
      !(mxid.nil? || @api.access_token.nil?)
    end

    def create_room(room_alias = nil, params = {})
      api.create_room(params.merge(room_alias: room_alias))
    end

    def join_room(room_id_or_alias)
      data = api.join_room(room_id_or_alias)
      ensure_room(data.fetch(:room_id, room_id_or_alias))
    end

    def find_room(room_id_or_alias)
      @rooms.fetch(room_id_or_alias, @rooms.values.find { |r| r.canonical_alias == room_id_or_alias })
    end

    def get_user(user_id)
      if cache == :all
        @users[user_id] ||= User.new(self, user_id)
      else
        User.new(self, user_id)
      end
    end

    def remove_room_alias(room_alias)
      api.remove_room_alias(room_alias)
    end

    def upload(content, content_type)
      data = api.media_upload(content, content_type)
      return data[:content_uri] if data.key? :content_uri
      raise MatrixUnexpectedResponseError, 'Upload succeeded, but no media URI returned'
    end

    def listen_for_events(timeout = 30, arguments = {})
      sync(arguments.merge(timeout: timeout))
    end

    def start_listener_thread(params = {})
      @should_listen = true
      thread = Thread.new { listen_forever(params) }
      @sync_thread = thread
      thread.run
    end

    def stop_listener_thread
      return unless @sync_thread
      @should_listen = false
      @sync_thread.join if @sync_thread.alive?
      @sync_thread = nil
    end

    private

    def listen_forever(params = {})
      timeout = params.fetch(:timeout, 30)
      params[:bad_sync_timeout] = params.fetch(:bad_sync_timeout, 5)
      params[:sync_interval] = params.fetch(:sync_interval, 30)

      bad_sync_timeout = params[:bad_sync_timeout]
      while @should_listen
        begin
          sync(timeout: timeout)
          bad_sync_timeout = params[:bad_sync_timeout]
          sleep(params[:sync_interval]) if params[:sync_interval] > 0
        rescue MatrixRequestError => ex
          logger.warn("A #{ex.class} occurred during sync")
          if ex.httpstatus >= 500
            logger.warn("Serverside error, retrying in #{bad_sync_timeout} seconds...")
            sleep params[:bad_sync_timeout]
            bad_sync_timeout = [bad_sync_timeout * 2, @bad_sync_timeout_limit].min
          end
        end
      end
    end

    def post_authentication(data)
      @mxid = data[:user_id]
      @api.access_token = data[:access_token]
      @api.device_id = data[:device_id]
      @api.homeserver = data[:home_server]
      access_token
    end

    def ensure_room(room_id)
      room_id = room_id.to_s unless room_id.is_a? String
      @rooms.fetch(room_id) { @rooms[room_id] = Room.new(self, room_id) }
    end

    def handle_state(room_id, state_event)
      return unless state_event.key? :type

      room = ensure_room(room_id)
      content = state_event[:content]
      case state_event[:type]
      when 'm.room.name'
        room.instance_variable_set '@name', content[:name]
      when 'm.room.canonical_alias'
        room.instance_variable_set '@canonical_alias', content[:alias]
      when 'm.room.topic'
        room.instance_variable_set '@topic', content[:topic]
      when 'm.room.aliases'
        room.instance_variable_get('@aliases').concat content[:aliases]
      when 'm.room.join_rules'
        room.instance_variable_set '@join_rule', content[:join_rule].to_sym
      when 'm.room.guest_access'
        room.instance_variable_set '@guest_access', content[:guest_access].to_sym
      when 'm.room.member'
        return unless cache == :all

        if content[:membership] == 'join'
          room.send :ensure_member, User.new(self, state_event[:state_key], display_name: content[:displayname])
        elsif %w[leave kick invite].include? content[:membership]
          room.members.delete_if { |m| m.id == state_event[:state_key] }
        end
      end
    end

    def sync(params = {})
      extra_params = {
        filter: sync_filter.to_json
      }
      extra_params[:since] = @next_batch unless @next_batch.nil?
      attempts = 0
      data = loop do
        begin
          break api.sync params.merge(extra_params)
        rescue MatrixConnectionError => ex
          raise ex if (attempts += 1) > params.fetch(:allow_sync_retry, 0)
        end
      end
      @next_batch = data[:next_batch]

      data[:presence][:events].each do |presence_update|
        fire_presence_event(MatrixEvent.new(self, presence_update))
      end

      data[:rooms][:invite].each do |room_id, invite|
        fire_invite_event(MatrixEvent.new(self, invite), room_id)
      end

      data[:rooms][:leave].each do |room_id, left|
        fire_leave_event(MatrixEvent.new(self, left), room_id)
      end

      data[:rooms][:join].each do |room_id, join|
        room = ensure_room(room_id)
        room.instance_variable_set '@prev_batch', join[:timeline][:prev_batch]
        join[:state][:events].each do |event|
          event[:room_id] = room_id
          handle_state(room_id, event)
        end

        join[:timeline][:events].each do |event|
          event[:room_id] = room_id
          room.send :put_event, event

          fire_event(MatrixEvent.new(self, event), event[:type])
        end

        join[:ephemeral][:events].each do |event|
          event[:room_id] = room_id
          room.send :put_ephemeral_event, event

          fire_ephemeral_event(MatrixEvent.new(self, event), event[:type])
        end
      end

      nil
    end
  end
end
