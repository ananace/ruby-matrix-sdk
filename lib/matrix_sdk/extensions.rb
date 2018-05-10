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

module MatrixSdk
  class EventHandlerArray < Hash
    def add_handler(filter = nil, id = nil, &block)
      id ||= block.hash
      self[id] = { filter: filter, id: id, block: block }
    end

    def remove_handler(id)
      delete id
    end

    def fire(event)
      reverse_each do |h|
        h[:block].call(event) unless event.matches? h[:filter]
      end
    end
  end

  class Event
    attr_writer :handled

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
    attr_accessor :event

    def initialize(sender, event = nil)
      @event = event
      super sender
    end

    def matches?(filter)
      return true if @filter.nil? || filter.nil?

      if filter.is_a? Regexp
        filter.match(@event[:type]) { true } || false
      else
        @event[:type] == filter
      end
    end
  end
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
      def fire_#{name}(ev)
        @on_#{name}.fire(ev)
        when_#{name}(ev) if !ev.handled?
      end

      def when_#{name}(ev); end
    "
  end

  class_eval "
    module #{module_name}
      attr_reader #{readers.join ', '}

      def initialize(*args)
        begin
          super(*args)
        rescue NoMethodError; end

        #{initializers.join}
      end

      #{methods.join}
    end

    include #{module_name}
  ", __FILE__, __LINE__ - 16
end
