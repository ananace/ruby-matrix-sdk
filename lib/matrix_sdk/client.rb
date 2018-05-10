require 'matrix_sdk'

require 'forwardable'

module MatrixSdk
  class Client
    extend Forwardable

    attr_reader :api, :rooms, :sync_token
    attr_accessor :cache, :mxid

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

      @bad_sync_timeout = 60 * 60

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
      post_registration(data)
    end

    def register_with_password(username, password)
      data = api.register(auth: { type: 'm.login.dummy' }, username: username, password: password)
      post_registration(data)
    end

    def login(username, password)
      data = api.login(user: username, password: password)
      @mxid = data[:user_id]
    end

    def logout
      api.logout
      @mxid = nil
    end

    def get_room(room_id)
      @rooms[room_id]
    end

    private

    def post_registration(data)
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

    def sync
      data = api.sync filter: { room: { timeline: { limit: 20 } } }.to_json

      data[:presence][:events].each do |presence_update|
      end

      data[:rooms][:invite].each do |_room_id, invite|
      end

      data[:rooms][:leave].each do |_room_id, left|
      end

      data[:rooms][:join].each do |_room_id, join|
        join[:state][:events].each do |event|
          handle_state(join, event)
        end
      end
    end
  end
end
