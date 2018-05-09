module MatrixSdk
  class Client
    attr_reader :api, :mxid, :rooms

    def initialize(hs_url, params = {})
      @api = Api.new hs_url, params

      @rooms = {}
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

      end
    end

    def sync
      data = api.sync filter: { room: { timeline: { limit: 20 } } }.to_json
      
      data[:presence][:events].each do |presence_update|
      end

      data[:rooms][:invite].each do |room, invite|
      end

      data[:rooms][:leave].each do |room, left|
      end

      data[:rooms][:join].each do |room, join|

        join[:state][:events].each do |event|
          handle_state(join, event)
        end
      end
    end
  end

  class Room
    attr_accessor :id, :name, :topic, :canonical_alias, :aliases, :join_rule, :guest_access

    def initialize(room_id, data = {})
      @id = room_id
      data.each do |k, v|
        instance_variable_set("@#{k}", v)
      end
    end
  end
end
