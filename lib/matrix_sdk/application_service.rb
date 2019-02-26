require 'matrix_sdk'

module MatrixSdk
  class ApplicationService
    attr_reader :api, :port

    def_delegators :@api,
                   :access_token, :access_token=, :device_id, :device_id=, :homeserver, :homeserver=,
                   :validate_certificate, :validate_certificate=

    def initialize(hs_url, application_secret:, legacy_routes: false, **params)
      logger.warning 'This abstraction is still under HEAVY development, expect errors'

      params = { protocols: %i[AS CS] }.merge(params).merge(access_token: application_secret)
      if hs_url.is_a? Api
        @api = hs_url
        params.each do |k, v|
          api.instance_variable_set("@#{k}", v) if api.instance_variable_defined? "@#{k}"
        end
      else
        @api = Api.new hs_url, params
      end

      @port = params.fetch(:port, 8888)

      @method_map = {}

      add_method(:GET, %r{^/_matrix/app/v1/users/(?<user>@.+:.+)$}, :do_get_user)
      add_method(:GET, %r{^/_matrix/app/v1/rooms/(?<room>#.+:.+)$}, :do_get_room)

      add_method(:GET, %r{^/_matrix/app/v1/thirdparty/protocol/(?<protocol>.+)$}, :do_get_3p_protocol_p)
      add_method(:GET, %r{^/_matrix/app/v1/thirdparty/user/(?<protocol>.+)$}, :do_get_3p_user_p)
      add_method(:GET, %r{^/_matrix/app/v1/thirdparty/location/(?<protocol>.+)$}, :do_get_3p_location_p)
      add_method(:GET, %r{^/_matrix/app/v1/thirdparty/user$}, :do_get_3p_user)
      add_method(:GET, %r{^/_matrix/app/v1/thirdparty/location$}, :do_get_3p_location)

      add_method(:PUT, %r{^/_matrix/app/v1/transactions/(?<txn_id>.+)$}, :do_put_transaction)

      if legacy_routes
        add_method(:GET, %r{^/users/(?<user>@.+:.+)$}, :do_get_user)
        add_method(:GET, %r{^/rooms/(?<room>#.+:.+)$}, :do_get_room)

        add_method(:GET, %r{^/_matrix/app/unstable/thirdparty/protocol/(?<protocol>.+)$}, :do_get_3p_protocol_p)
        add_method(:GET, %r{^/_matrix/app/unstable/thirdparty/user/(?<protocol>.+)$}, :do_get_3p_user_p)
        add_method(:GET, %r{^/_matrix/app/unstable/thirdparty/location/(?<protocol>.+)$}, :do_get_3p_location_p)
        add_method(:GET, %r{^/_matrix/app/unstable/thirdparty/user$}, :do_get_3p_user)
        add_method(:GET, %r{^/_matrix/app/unstable/thirdparty/location$}, :do_get_3p_location)

        add_method(:PUT, %r{^/transactions/(?<txn_id>[^/]+)$}, :do_put_transaction)
      end

      start_server
    end

    def logger
      @logger ||= Logging.logger[self]
    end

    def port=(port)
      raise ArgumentError, 'Port must be a number' unless port.is_a? Numeric
      @port = port
    end

    protected

    def add_method(method, regex, proc = nil, &block)
      proc ||= block
      raise ArgumentError, 'No method specified' if proc.nil?
      (@method_map[method] ||= {})[regex] = proc
    end

    def do_get_user(user:, **params)
      [user, params]
      raise NotImplementedError
    end

    def do_get_room(room:, **params)
      [room, params]
      raise NotImplementedError
    end

    def do_get_3p_protocol_p(protocol:, **params)
      [protocol, params]
      raise NotImplementedError
    end

    def do_get_3p_user_p(protocol:, **params)
      [protocol, params]
      raise NotImplementedError
    end

    def do_get_3p_location_p(protocol:, **params)
      [protocol, params]
      raise NotImplementedError
    end

    def do_get_3p_location(**params)
      [protocol, params]
      raise NotImplementedError
    end

    def do_get_3p_user(**params)
      [protocol, params]
      raise NotImplementedError
    end

    def do_put_transaction(txn_id:, **params)
      [txn_id, params]
      raise NotImplementedError
    end

    private

    def handle_request(request, response)
      req_method = request.request_method.to_s.to_sym
      req_uri = request.request_uri

      map = @method_map[req_method]
      raise WEBrick::HTTPStatus[405], {}.to_json if map.nil?

      method = map.find { |k, _v| k =~ req_uri.path }.last
      match = Regexp.last_match
      match_hash = Hash[match.names.zip(match.captures)].merge(
        request: request,
        response: response
      )

      if method.is_a? Symbol
        send method, match_hash
      else
        method.call match_hash
      end
    end

    def start_server
      @server = WEBrick::HTTPServer.new Port: @port

      @server.mount_proc '/', &:handle_request

      @server.start
    end

    def stop_server
      @server.shutdown if @server
      @server = nil
    end
  end
end
