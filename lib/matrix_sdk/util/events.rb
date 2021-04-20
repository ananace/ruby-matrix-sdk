# frozen_string_literal: true

module MatrixSdk
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
        h[:block].call(event) if !h[:filter] || event.matches?(h[:filter], filter)
      rescue StandardError => e
        logger.error "#{e.class.name} occurred when firing event (#{event})\n#{e}"

        raise e if @reraise_exceptions
      end
    end
  end

  class Event
    extend MatrixSdk::Extensions

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

  class ErrorEvent < Event
    attr_accessor :error

    def initialize(error, source)
      @error = error
      super source
    end

    def source
      @sender
    end
  end

  class MatrixEvent < Event
    attr_accessor :event, :filter
    alias data event

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

    def respond_to_missing?(method, *)
      return true if event.key? method

      super
    end
  end
end
