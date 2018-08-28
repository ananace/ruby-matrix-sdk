module MatrixSdk
  class MXID
    attr_accessor :sigil, :localpart, :domain

    def initialize(identifier)
      raise ArugmentError, 'Identifier must be a String' unless identifier.is_a? String
      raise ArgumentError, 'Identifier is too long' if identifier.size > 255
      raise ArugmentError, 'Identifier lacks required data' unless identifier =~ %r{^[@!$+#][^:]+:[^:]+(?::\d+)$}

      @sigil = identifier[0]
      @localpart, @domain = identifier[1..-1].split(':')

      raise ArgumentError, 'Identifier is not a valid MXID' unless valid?
    end

    def to_s
      "#{sigil}#{localpart}:#{domain}"
    end

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

    def valid?
      !type.nil?
    end

    def user?
      type == :user_id
    end

    def group?
      type == :group_id
    end

    def room?
      type == :room_id || type == :room_alias
    end

    def event?
      type == :event_id
    end

    def room_id?
      type == :room_id
    end

    def room_alias?
      type == :room_alias
    end
  end
end
