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
  class EventHandlerArray < Array
    def add
      raise 'Use `add_handler` to add event handlers'
    end

    def add_handler(code = nil, &block)
      if code
        push(code)
      else
        push(block)
      end
    end

    def remove_handler(code)
      delete(code)
    end

    def fire(event)
      reverse_each { |h| h.call(event) }
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

  # rubocop:disable Security/Eval
  eval "
    module #{module_name}
      attr_reader #{readers.join ', '}

      def initialize(*args)
        begin
          super(*args)
        rescue NoMethodError; end

        #{initalizers.join}
      end

      #{methods.join}
    end

    include #{module_name}
  ", __FILE__, __LINE__
  # rubocop:enable Security/Eval
end
