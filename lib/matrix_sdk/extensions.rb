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

unless Object.respond_to? :yield_self
  class Object
    def yield_self
      yield(self)
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
      reentrant = caller_locations.any? { |l| l.absolute_path == __FILE__ && l.label == 'inspect' }
      "\#{to_s[0..-2]} \#{instance_variables
        .reject { |f| %i[#{symbols.map { |s| "@#{s}" }.join ' '}].include? f }
        .map { |f| "\#{f}=\#{reentrant ? instance_variable_get(f) : instance_variable_get(f).inspect}" }.join " " }}>"
    end
  *, __FILE__, __LINE__ - 7
end

module MatrixSdk
  module Logging
    def logger
      @logger ||= ::Logging.logger[self]
    end
  end

  class EventHandlerArray < Hash
    include MatrixSdk::Logging
    attr_accessor :reraise_exceptions

    def initialize(*args)
      @reraise_exceptions = false

      super(*args)
    end

    def add_handler(filter = nil, id = nil, &block)
      id ||= block.hash
      self[id] = { filter: filter, id: id, block: block }
    end

    def remove_handler(id)
      delete id
    end

    def fire(event, filter = nil)
      reverse_each do |_k, h|
        begin
          h[:block].call(event) if event.matches?(h[:filter], filter)
        rescue StandardError => e
          logger.error "#{e.class.name} occurred when firing event (#{event})\n#{e}"

          raise e if @reraise_exceptions
        end
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

    def [](key)
      event[key]
    end

    def to_s
      "#{event[:type]}: #{event.reject { |k, _v| k == :type }.to_json}"
    end

    def method_missing(method, *args)
      return event[method] if event.key? method

      super
    end

    def respond_to_missing?(method)
      event.key? method
    end
  end
end
