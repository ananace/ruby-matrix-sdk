# frozen_string_literal: true

require 'pp'

unless Object.respond_to? :yield_self
  class Object
    def yield_self
      yield(self)
    end
  end
end

module MatrixSdk
  module Extensions
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
        include PP::ObjectMixin

        def pretty_print_instance_variables
          instance_variables
            .reject { |f| %i[#{symbols.map { |s| "@#{s}" }.join ' '}].include? f }
            .sort
        end

        def pretty_print(pp)
          pp.pp(self)
        end

        alias inspect pretty_print_inspect
      *, __FILE__, __LINE__ - 14
    end
  end

  module Logging
    def logger
      return MatrixSdk.logger if MatrixSdk.global_logger?

      @logger || ::Logging.logger[self]
    end

    def logger=(logger)
      @logger = logger
    end
  end
end
