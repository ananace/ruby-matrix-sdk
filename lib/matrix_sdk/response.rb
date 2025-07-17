# frozen_string_literal: true

module MatrixSdk
  # An usability wrapper for API responses as an extended [Hash]
  # All results can be read as both hash keys and as read-only methods on the key
  #
  # @example Simple usage of the response wrapper to get the avatar URL
  #   resp = api.get_avatar_url(api.whoami?.user_id)
  #   # => { avatar_url: 'mxc://matrix.org/SDGdghriugerRg' }
  #   resp.is_a? Hash
  #   # => true
  #   resp.key? :avatar_url
  #   # => true
  #   resp.avatar_url
  #   # => 'mxc://matrix.org/SDGdghriugerRg'
  #   resp.api.set_avatar_url(...)
  #   # => {}
  #
  # @since 0.0.3
  # @see Hash
  # @!attribute [r] api
  #   @return [Api] The API connection that returned the response
  module Response
    def self.new(api, data, raw_data = nil, parent: nil)
      if data.is_a? Array
        raise ArgumentError, 'Input data was not an array of hashes' unless data.all? { |v| v.is_a? Hash }

        data.each do |value|
          Response.new api, value, raw_data, parent: data
        end
        data.instance_variable_set(:@raw_data, raw_data) if raw_data
        return data
      end

      return data if data.instance_variables.include? :@api

      raise ArgumentError, 'Input data was not a hash' unless data.is_a? Hash

      data.extend(Extensions)
      data.instance_variable_set(:@api, api)
      data.instance_variable_set(:@parent, parent) if parent
      data.instance_variable_set(:@raw_data, raw_data) if raw_data

      data.select { |_k, v| v.is_a? Hash }
          .each { |_v, v| Response.new api, v, parent: data }

      data
    end

    module Extensions
      attr_reader :api

      def raw_data!
        @raw_data || @parent&.raw_data! || @parent&.instance_variable_get(:@raw_data)
      end

      def respond_to_missing?(name, *_args)
        return true if key? name

        super
      end

      def method_missing(name, *args)
        return fetch(name) if key?(name) && args.empty?

        super
      end
    end
  end
end
