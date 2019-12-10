# frozen_string_literal: true

module MatrixSdk
  class MXID
    attr_accessor :sigil, :localpart, :domain, :port

    # @param identifier [String] The Matrix ID string in the format of '&<localpart>:<domain>' where '&' is the sigil
    def initialize(identifier)
      raise ArgumentError, 'Identifier must be a String' unless identifier.is_a? String
      raise ArgumentError, 'Identifier is too long' if identifier.size > 255
      raise ArgumentError, 'Identifier lacks required data' unless identifier =~ %r{^([@!$+#][^:]+:[^:]+(?::\d+)?)|(\$[A-Za-z0-9+/]+)$}

      @sigil = identifier[0]
      @localpart, @domain, @port = identifier[1..-1].split(':')
      @port = @port.to_i if @port

      raise ArgumentError, 'Identifier is not a valid MXID' unless valid?
    end

    def homeserver
      port_s = port ? ':' + port.to_s : ''
      domain ? ':' + domain + port_s : ''
    end

    def to_s
      "#{sigil}#{localpart}#{homeserver}"
    end

    # Returns the type of the ID
    #
    # @return [Symbol] The MXID type, one of (:user_id, :room_id, :event_id, :group_id, or :room_alias)
    def type
      case sigil
      when '@'
        :user_id
      when '!'
        :room_id
      when '$'
        :event_id
      when '+'
        :group_id
      when '#'
        :room_alias
      end
    end

    # Checks if the ID is valid
    #
    # @return [Boolean] If the ID is a valid Matrix ID
    def valid?
      !type.nil?
    end

    # Check if the ID is of a user
    # @return [Boolean] if the ID is of the user_id type
    def user?
      type == :user_id
    end

    # Check if the ID is of a group
    # @return [Boolean] if the ID is of the group_id type
    def group?
      type == :group_id
    end

    # Check if the ID is of a room
    # @return [Boolean] if the ID is of the room_id or room_alias types
    def room?
      type == :room_id || type == :room_alias
    end

    # Check if the ID is of a event
    # @return [Boolean] if the ID is of the event_id type
    def event?
      type == :event_id
    end

    # Check if the ID is a room_id
    # @return [Boolean] if the ID is of the room_id type
    def room_id?
      type == :room_id
    end

    # Check if the ID is a room_alias
    # @return [Boolean] if the ID is of the room_alias type
    def room_alias?
      type == :room_alias
    end
  end
end
