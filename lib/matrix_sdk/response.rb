module MatrixSdk
  module Response
    def self.new(api, data)
      data.extend(Extensions)
      data.instance_variable_set(:@api, api)
      data
    end

    module Extensions
      attr_reader :api

      def respond_to_missing?(name)
        key? name
      end

      def method_missing(name, *args)
        return fetch(name) if key?(name) && args.empty?
        super
      end
    end
  end
end
