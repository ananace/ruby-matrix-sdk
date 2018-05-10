require 'matrix_sdk'

require 'forwardable'

module MatrixSdk
  class Client
    extend Forwardable

    attr_reader :api, :rooms, :sync_token
    attr_accessor :cache, :mxid, :sync_filter

    events :event, :presence_event, :invite_event, :left_event, :ephemeral_event

    alias user_id mxid
    alias user_id= mxid=

    def_delegators :@api,
                   :access_token, :access_token=, :device_id, :device_id=, :homeserver, :homeserver=,
                   :validate_certificate, :validate_certificate=

    def initialize(hs_url, params = {})
      params[:user_id] = params[:mxid] if params[:mxid]
      raise ArgumentError, 'Must provide user_id with access_token' if params[:access_token] && !params[:user_id]

      @api = Api.new hs_url, params

      @rooms = {}
      @cache = :all

      @sync_token = nil
      @sync_thread = nil
      @sync_filter = { room: { timeline: { limit: params.fetch(:sync_filter_limit, 20) } } }

      @should_listen = false

      @bad_sync_timeout_limit = 60 * 60

      params.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end

      raise ArgumentError, 'Cache value must be one of of [:all, :some, :none]' unless %i[all some none].include? @cache

      return unless params[:user_id]
      @mxid = params[:user_id]
      sync
    end

    def register_as_guest
      data = api.register(kind: :guest)
      post_authentication(data)
    end

    def register_with_password(username, password)
      data = api.register(auth: { type: 'm.login.dummy' }, username: username, password: password)
      post_authentication(data)
    end

    def login(username, password, params = {})
      data = api.login(user: username, password: password)
      post_authentication(data)

      sync(timeout: 15) unless params[:no_sync]
    end

    def logout
      api.logout
      @api.access_token = nil
      @mxid = nil
    end

    def create_room(room_alias = nil, params = {})
      api.create_room(params.merge(room_alias: room_alias))
    end

    def join_room(room_id_or_alias)
      data = api.join_room(room_id_or_alias)
      ensure_room(data.fetch(:room_id, room_id_or_alias))
    end

    def get_user(user_id)
      User.new(self, user_id)
    end

    def remove_room_alias(room_alias)
      api.remove_room_alias(room_alias)
    end

    def upload(content, content_type)
      data = api.media_upload(content, content_type)
      return data[:content_uri] if data.key? :content_uri
      raise MatrixUnexpectedResponseError, 'Upload succeeded, but no media URI returned'
    end

    def listen_for_events(timeout = 30)
      sync(timeout: timeout)
    end

    def listen_forever(params = {})
      timeout = params.fetch(:timeout, 30)
      params[:bad_sync_timeout] = params.fetch(:bad_sync_timeout, 5)

      bad_sync_timeout = params[:bad_sync_timeout]
      while @should_listen
        begin
          sync(timeout: timeout)
          bad_sync_timeout = params[:bad_sync_timeout]
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

    def start_listener_thread(params = {})
      @should_listen = true
      thread = Thread.new(params, &:listen_forever)
      @sync_thread = thread
      thread.run
    end

    def stop_listener_thread
      return unless @sync_thread
      @should_listen = false
      @sync_thread.join
      @sync_thread = nil
    end

    private

    def post_authentication(data)
      @mxid = data[:user_id]
      @api.access_token = data[:access_token]
      @api.device_id = data[:device_id]
      @api.homeserver = data[:home_server]
      access_token
    end

    def ensure_room(room_id)
      @rooms[room_id] ||= Room.new room_id
    end

    def handle_state(room_id, state_event)
      return unless state_event.key? :type

      room = ensure_room(room_id)
      content = state.event[:content]
      case state.event[:type]
      when 'm.room.name'
        room.name = content[:name]
      when 'm.room.canonical_alias'
        room.canonical_alias = content[:alias]
      when 'm.room.topic'
        room.topic = content[:topic]
      when 'm.room.aliases'
        room.aliases = content[:aliases]
      when 'm.room.join_rules'
        room.join_rule = content[:join_rule].to_sym
      when 'm.room.guest_access'
        room.guest_access = content[:guest_access].to_sym
      when 'm.room.member'
        return unless cache == :all

        if content[:membership] == 'join'
          # Make members
        elsif %w[leave kick invite].include? content[:membership]
          room.members.delete_if { |m| m.id == state_event[:state_key] }
        end
      end
    end

    def sync(params = {})
      data = api.sync filter: sync_filter.to_json

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
        room.prev_batch = join[:timeline][:prev_batch]
        join[:state][:events].each do |event|
          event[:room_id] = room_id
          handle_state(join, event)
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
    end
  end
end
