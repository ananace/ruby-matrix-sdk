# frozen_string_literal: true

module MatrixSdk
  class MXID
    MXID_REX = %r{\A(?<sigil>[^\w\s])(((?<localpart>[^:\0]+):(?<domain>[0-9a-z.-]+|\[[0-9A-Fa-f:.]+\])(?::(?<port>\d+))?)|(?<opaque>[^:]+))\z}i.freeze

    attr_accessor :sigil, :localpart, :opaque, :domain, :port

    # @param identifier [String] The Matrix ID string in the format of '&<localpart>:<domain>(:<port>)' or '&<base64>' where '&' is the sigil
    def initialize(identifier)
      raise ArgumentError, 'Identifier must be a String' unless identifier.is_a? String
      raise ArgumentError, 'Identifier is too long' if identifier.size > 255
      match = MXID_REX.match(identifier)
      raise ArgumentError, 'Identifier is not of valid format' unless match

      @sigil = match[:sigil]
      @localpart = match[:localpart]
      @opaque = match[:opaque]
      @domain = match[:domain]
      @port = match[:port]&.to_i

      raise ArgumentError, 'Identifier is not a valid MXID' unless valid?
    end

    # Gets the homeserver part of the ID
    #
    # @example A simple MXID
    #   id = MXID.new('@alice:example.org')
    #   id.homeserver
    #   # => 'example.org'
    #
    # @example A fully qualified MXID
    #   id = MXID.new('@user:some.direct.domain:443')
    #   id.homeserver
    #   # => 'some.direct.domain:443'
    #
    # @return [String]
    def homeserver
      port_s = port ? ":#{port}" : ''
      domain ? domain + port_s : ''
    end

    # Gets the homserver part of the ID as a suffix (':homeserver')
    def homeserver_suffix
      ":#{homeserver}" if domain
    end

    def to_s
      return "#{sigil}#{opaque}" if opaque

      "#{sigil}#{localpart}#{homeserver_suffix}"
    end

    alias to_str to_s

    # Returns the type of the ID
    #
    # @return [Symbol] The MXID type, one of (:user_id, :room_id, :event_id, :group_id, or :room_alias)
    def type
      {
        '@' => :user_id,
        '!' => :room_id,
        '$' => :event_id,
        '+' => :group_id,
        '#' => :room_alias
      }[sigil]
    end

    # Checks if the ID is valid
    #
    # @return [Boolean] If the ID is a valid Matrix ID
    def valid?
      return false if type.nil?

      case type
      when :user_id, :group_id, :room_alias
        return false unless domain
      end

      true
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

    # Converts the MXID to a matrix: URI according to MSC2312
    # @param event_id [String,MXID] An event ID to append to the URI (only valid for rooms)
    # @param action [String,Symbol] The action that should be requested
    # @param via [Array[String]] The list of servers to use for a join
    # @see https://github.com/matrix-org/matrix-doc/blob/master/proposals/2312-matrix-uri.md
    def to_uri(event_id: nil, action: nil, via: nil)
      uri = ''

      case sigil
      when '@'
        raise ArgumentError, "can't provide via for user URIs" if via
        raise ArgumentError, "can't provide event_id for user URIs" if event_id

        uri += 'u'
      when '#'
        uri += 'r'
      when '!'
        uri += 'roomid'
      else
        raise ArgumentError, "this MXID can't be converted to a URI"
      end

      uri = "matrix:#{uri}/#{localpart}#{homeserver_suffix}"

      uri += "/e/#{event_id.to_s.delete_prefix('$')}" if event_id
      query = []
      query << "action=#{action}" if action
      [via].flatten.compact.each { |v| query << "via=#{v}" }

      uri += "?#{query.join('&')}" unless query.empty?

      URI(uri)
    end

    # Check if two MXIDs are equal
    # @return [Boolean]
    def ==(other)
      to_s == other.to_s
    end
  end
end
