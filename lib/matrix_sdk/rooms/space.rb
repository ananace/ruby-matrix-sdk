# frozen_string_literal: true

module MatrixSdk::Rooms
  class Space < MatrixSdk::Room
    TYPE = 'm.space'

    def tree(suggested_only: nil, max_rooms: nil)
      begin
        data = client.api.request :get, :client_r0, "/rooms/#{id}/spaces", query: {
          suggested_only: suggested_only,
          max_rooms_per_space: max_rooms
        }.compact
      rescue MatrixRequestError
        data = client.api.request :get, :client_unstable, "/org.matrix.msc2946/rooms/#{id}/spaces", query: {
          suggested_only: suggested_only,
          max_rooms_per_space: max_rooms
        }.compact
      end

      rooms = data.rooms.map do |r|
        next if r[:room_id] == id

        room = client.ensure_room(r[:room_id])
        room.instance_variable_set :@room_type, r[:room_type] if r.key? :room_type
        room = room.to_space if room.space?

        # Inject available room information
        r.each do |k, v|
          if room.respond_to?("#{k}_cached?".to_sym) && send("#{k}_cached?".to_sym)
            room.send(:tinycache_adapter).write(k, v)
          elsif room.instance_variable_defined? "@#{k}"
            room.instance_variable_set("@#{k}", v)
          end
        end
        room
      end
      rooms.compact!

      grouping = {}
      data.events.each do |ev|
        next unless ev[:type] == 'm.space.child'
        next unless ev[:content].key? :via

        d = (grouping[ev[:room_id]] ||= [])
        d << ev[:state_key]
      end

      build_tree = proc do |entry|
        next if entry.nil?

        room = self if entry == id
        room ||= rooms.find { |r| r.id == entry }
        puts "Unable to find room for entry #{entry}" unless room
        # next if room.nil?

        ret = {
          room => []
        }

        grouping[entry]&.each do |child|
          if grouping.key?(child)
            ret[room] << build_tree.call(child)
          else
            child_r = self if child == id
            child_r ||= rooms.find { |r| r.id == child }

            ret[room] << child_r
          end
        end

        ret[room].compact!

        ret
      end

      build_tree.call(id)
    end
  end
end
