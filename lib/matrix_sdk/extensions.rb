module URI
  class MATRIX < Generic
    def full_path
      select(:host, :port, :path, :query, :fragment)
        .reject(&:nil?)
        .join
    end
  end

  @@schemes['MXC'] = MATRIX
end

def events(*symbols)
  module_name = "#{name}Events"

  initializers = []
  readers = []
  methods = []

  symbols.each do |sym|
    name = sym.to_s

    initializers << "
      @on_#{name} = MatrixSdk::EventHandlerArray.new
    "
    readers << ":on_#{name}"
    methods << "
      def fire_#{name}(ev, filter = nil)
        @on_#{name}.fire(ev, filter)
        when_#{name}(ev) if !ev.handled?
      end

      def when_#{name}(ev); end
    "
  end

  class_eval "
    module #{module_name}
      attr_reader #{readers.join ', '}

      def event_initialize
        #{initializers.join}
      end

      #{methods.join}
    end

    include #{module_name}
  ", __FILE__, __LINE__ - 12
end

def ignore_inspect(*symbols)
  class_eval %*
    def inspect
      "#<\#{self.class.name}:\#{"%016x" % (object_id << 1)} \#{instance_variables.reject { |f| %i[#{symbols.map { |s| "@#{s}" }.join ' '}].include? f }.map { |f| "\#{f}=\#{instance_variable_get(f).inspect}" }.join ' ' }>"
    end
  *, __FILE__, __LINE__ - 4
end

module MatrixSdk
  class EventHandlerArray < Hash
    def add_handler(filter = nil, id = nil, &block)
      id ||= block.hash
      self[id] = { filter: filter, id: id, block: block }
    end

    def remove_handler(id)
      delete id
    end

    def fire(event, filter = nil)
      reverse_each do |_k, h|
        h[:block].call(event) if event.matches?(h[:filter], filter)
      end
    end
  end

  class Event
    attr_writer :handled

    ignore_inspect :sender

    def initialize(sender)
      @sender = sender
      @handled = false
    end

    def handled?
      @handled
    end

    def matches?(_filter)
      true
    end
  end

  class MatrixEvent < Event
    attr_accessor :event, :filter

    ignore_inspect :sender

    def initialize(sender, event = nil, filter = nil)
      @event = event
      @filter = filter || @event[:type]
      super sender
    end

    def matches?(filter, filter_override = nil)
      return true if filter_override.nil? && (@filter.nil? || filter.nil?)

      to_match = filter_override || @filter
      if filter.is_a? Regexp
        filter.match(to_match) { true } || false
      else
        to_match == filter
      end
    end
  end
end
