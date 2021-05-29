# frozen_string_literal: true

module MatrixSdk::Rooms
  class Space < MatrixSdk::Room
    TYPE = 'm.space'

    def tree
      data = client.api.get_room_state_all(id)
      children = data.select { |chunk| chunk[:type] == 'm.space.child' }
                     .map do |chunk|
        room = client.ensure_room chunk[:state_key]
        next room unless room.space?

        room.as_space.tree
      end

      {
        self => children
      }
    end
  end
end
