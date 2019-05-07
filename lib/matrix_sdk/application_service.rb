require 'matrix_sdk'

module MatrixSdk
  class ApplicationService
    include MatrixSdk::Logging
    attr_reader :api, :port

    def_delegators :@api,
                   :access_token, :access_token=, :device_id, :device_id=, :homeserver, :homeserver=,
                   :validate_certificate, :validate_certificate=

    def initialize(hs_url, as_token:, hs_token:, default_routes: true, **params)
      logger.warning 'This abstraction is still under HEAVY development, expect errors'

      params = { protocols: %i[AS CS] }.merge(params).merge(access_token: as_token)
      if hs_url.is_a? Api
        @api = hs_url
        params.each do |k, v|
          api.instance_variable_set("@#{k}", v) if api.instance_variable_defined? "@#{k}"
        end
      else
        @api = Api.new hs_url, params
      end

      @id = params.fetch(:id, MatrixSdk::Api::USER_AGENT)
      @port = params.fetch(:port, 8888)
      @url = params.fetch(:url, URI("http://localhost:#{@port}"))
      @as_token = as_token
      @hs_token = hs_token

      @method_map = {}

      if default_routes
        add_method(:GET, '/_matrix/app/v1/users/', %r{^/_matrix/app/v1/users/(?<user>[^/]+)$}, :do_get_user)
        add_method(:GET, '/_matrix/app/v1/rooms/', %r{^/_matrix/app/v1/rooms/(?<room>[^/]+)$}, :do_get_room)

        add_method(:GET, '/_matrix/app/v1/thirdparty/protocol/', %r{^/_matrix/app/v1/thirdparty/protocol/(?<protocol>[^/]+)$}, :do_get_3p_protocol_p)
        add_method(:GET, '/_matrix/app/v1/thirdparty/user/', %r{^/_matrix/app/v1/thirdparty/user/(?<protocol>[^/]+)$}, :do_get_3p_user_p)
        add_method(:GET, '/_matrix/app/v1/thirdparty/location/', %r{^/_matrix/app/v1/thirdparty/location/(?<protocol>[^/]+)$}, :do_get_3p_location_p)
        add_method(:GET, '/_matrix/app/v1/thirdparty/user', %r{^/_matrix/app/v1/thirdparty/user$}, :do_get_3p_user)
        add_method(:GET, '/_matrix/app/v1/thirdparty/location', %r{^/_matrix/app/v1/thirdparty/location$}, :do_get_3p_location)

        add_method(:PUT, '/_matrix/app/v1/transactions/', %r{^/_matrix/app/v1/transactions/(?<txn_id>[^/]+)$}, :do_put_transaction)

        if params.fetch(:legacy_routes, false)
          add_method(:GET, '/users/', %r{^/users/(?<user>[^/]+)$}, :do_get_user)
          add_method(:GET, '/rooms/', %r{^/rooms/(?<room>[^/]+)$}, :do_get_room)

          add_method(:GET, '/_matrix/app/unstable/thirdparty/protocol/', %r{^/_matrix/app/unstable/thirdparty/protocol/(?<protocol>[^/]+)$}, :do_get_3p_protocol_p)
          add_method(:GET, '/_matrix/app/unstable/thirdparty/user/', %r{^/_matrix/app/unstable/thirdparty/user/(?<protocol>[^/]+)$}, :do_get_3p_user_p)
          add_method(:GET, '/_matrix/app/unstable/thirdparty/location/', %r{^/_matrix/app/unstable/thirdparty/location/(?<protocol>[^/]+)$}, :do_get_3p_location_p)
          add_method(:GET, '/_matrix/app/unstable/thirdparty/user', %r{^/_matrix/app/unstable/thirdparty/user$}, :do_get_3p_user)
          add_method(:GET, '/_matrix/app/unstable/thirdparty/location', %r{^/_matrix/app/unstable/thirdparty/location$}, :do_get_3p_location)

          add_method(:PUT, '/transactions/', %r{^/transactions/(?<txn_id>[^/]+)$}, :do_put_transaction)
        end
      end

      start_server
    end

    def registration
      {
        id: @id,
        url: @url,
        as_token: @as_token,
        hs_token: @hs_token,
        sender_localpart: '',
        namespaces: {
          users: [],
          aliases: [],
          rooms: []
        },
        rate_limited: false,
        protocols: []
      }
    end

    def port=(port)
      raise ArgumentError, 'Port must be a number' unless port.is_a? Numeric

      raise NotImplementedError, "Can't change port of a running server" if server.status != :Stop

      @port = port
    end

    protected

    def add_method(verb, prefix, regex, proc = nil, &block)
      proc ||= block
      raise ArgumentError, 'No method specified' if proc.nil?

      method_entry = (@method_map[verb] ||= {})[regex] = {
        verb: verb,
        prefix: prefix,
        proc: proc
      }
      return true unless @server

      server.mount_proc(method.prefix) { |req, res| _handle_proc(verb, method_entry, req, res) }
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

    def start_server
      server.start

      @method_map.each do |verb, method_entry|
        # break if verb != method_entry[:verb]

        method = method_entry[:proc]
        server.mount_proc(method.prefix) { |req, res| _handle_proc(verb, method_entry, req, res) }
      end

      logger.info "Application Service is now running on port #{port}"
    end

    def stop_server
      @server.shutdown if @server
      @server = nil
    end

    private

    def _handle_proc(verb, method_entry, req, res)
      logger.debug "Received request for #{verb} #{method_entry}"
      match = regex.match(req.request_uri.path)
      match_hash = Hash[match.names.zip(match.captures)].merge(
        request: req,
        response: res
      )

      if method.is_a? Symbol
        send method, match_hash
      else
        method.call match_hash
      end
    end

    def server
      @server ||= WEBrick::HTTPServer.new(Port: port, ServerSoftware: "#{MatrixSdk::Api::USER_AGENT} (Ruby #{RUBY_VERSION})").tap do |server|
        server.mount_proc '/', &:handle_request
      end
    end

    def handle_request(request, response)
      logger.debug "Received request #{request.inspect}"

      req_method = request.request_method.to_s.to_sym
      req_uri = request.request_uri

      map = @method_map[req_method]
      raise WEBrick::HTTPStatus[405], { message: 'Unsupported verb' }.to_json if map.nil?

      discovered = map.find { |k, _v| k =~ req_uri.path }
      raise WEBrick::HTTPStatus[404], { message: 'Unknown request' }.to_json if discovered.nil?

      method = discovered.last
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
  end
end
