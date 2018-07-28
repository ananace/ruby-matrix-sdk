module MatrixSdk
  class Response
    attr_reader :api, :raw

    def initialize(api, data)
      @api = api
      @raw = data
    end

    def inspect
      raw.inspect
    end

    def [](name)
      raw[name]
    end

    def respond_to_missing?(name)
      raw.key? name
    end

    def method_missing(name, *args)
      return raw.fetch(name) if raw.key?(name) && args.empty?
      super
    end
  end
end
