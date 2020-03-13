# frozen_string_literal: true

require 'matrix_sdk'

require 'erb'
require 'net/http'
require 'openssl'
require 'uri'

module MatrixSdk
  class Api
    extend MatrixSdk::Extensions
    include MatrixSdk::Logging

    USER_AGENT = "Ruby Matrix SDK v#{MatrixSdk::VERSION}"
    DEFAULT_HEADERS = {
      'accept' => 'application/json',
      'user-agent' => USER_AGENT
    }.freeze

    attr_accessor :access_token, :connection_address, :connection_port, :device_id, :autoretry, :global_headers
    attr_reader :homeserver, :validate_certificate, :open_timeout, :read_timeout, :well_known, :proxy_uri

    ignore_inspect :access_token, :logger

    # @param homeserver [String,URI] The URL to the Matrix homeserver, without the /_matrix/ part
    # @param params [Hash] Additional parameters on creation
    # @option params [Symbol[]] :protocols The protocols to include (:AS, :CS, :IS, :SS), defaults to :CS
    # @option params [String] :address The connection address to the homeserver, if different to the HS URL
    # @option params [Integer] :port The connection port to the homeserver, if different to the HS URL
    # @option params [String] :access_token The access token to use for the connection
    # @option params [String] :device_id The ID of the logged in decide to use
    # @option params [Boolean] :autoretry (true) Should requests automatically be retried in case of rate limits
    # @option params [Boolean] :validate_certificate (false) Should the connection require valid SSL certificates
    # @option params [Integer] :transaction_id (0) The starting ID for transactions
    # @option params [Numeric] :backoff_time (5000) The request backoff time in milliseconds
    # @option params [Numeric] :open_timeout (60) The timeout in seconds to wait for a TCP session to open
    # @option params [Numeric] :read_timeout (240) The timeout in seconds for reading responses
    # @option params [Hash] :global_headers Additional headers to set for all requests
    # @option params [Boolean] :skip_login Should the API skip logging in if the HS URL contains user information
    # @option params [Hash] :well_known The .well-known object that the server was discovered through, should not be set manually
    def initialize(homeserver, **params)
      @homeserver = homeserver
      raise ArgumentError, 'Homeserver URL must be String or URI' unless @homeserver.is_a?(String) || @homeserver.is_a?(URI)

      @homeserver = URI.parse("#{'https://' unless @homeserver.start_with? 'http'}#{@homeserver}") unless @homeserver.is_a? URI
      @homeserver.path.gsub!(/\/?_matrix\/?/, '') if @homeserver.path =~ /_matrix\/?$/
      raise ArgumentError, 'Please use the base URL for your HS (without /_matrix/)' if @homeserver.path.include? '/_matrix/'

      @proxy_uri = params.fetch(:proxy_uri, nil)
      @connection_address = params.fetch(:address, nil)
      @connection_port = params.fetch(:port, nil)
      @access_token = params.fetch(:access_token, nil)
      @device_id = params.fetch(:device_id, nil)
      @autoretry = params.fetch(:autoretry, true)
      @validate_certificate = params.fetch(:validate_certificate, false)
      @transaction_id = params.fetch(:transaction_id, 0)
      @backoff_time = params.fetch(:backoff_time, 5000)
      @open_timeout = params.fetch(:open_timeout, 60)
      @read_timeout = params.fetch(:read_timeout, 240)
      @well_known = params.fetch(:well_known, {})
      @global_headers = DEFAULT_HEADERS.dup
      @global_headers.merge!(params.fetch(:global_headers)) if params.key? :global_headers
      @http = nil

      ([params.fetch(:protocols, [:CS])].flatten - protocols).each do |proto|
        self.class.include MatrixSdk::Protocols.const_get(proto)
      end

      login(user: @homeserver.user, password: @homeserver.password) if @homeserver.user && @homeserver.password && !@access_token && !params[:skip_login] && protocol?(:CS)
      @homeserver.userinfo = '' unless params[:skip_login]
    end

    # Create an API connection to a domain entry
    #
    # This will follow the server discovery spec for client-server and federation
    #
    # @example Opening a Matrix API connection to a homeserver
    #   hs = MatrixSdk::API.new_for_domain 'example.com'
    #   hs.connection_address
    #   # => 'matrix.example.com'
    #   hs.connection_port
    #   # => 443
    #
    # @param domain [String] The domain to set up the API connection for, can contain a ':' to denote a port
    # @param target [:client,:identity,:server] The target for the domain lookup
    # @param keep_wellknown [Boolean] Should the .well-known response be kept for further handling
    # @param params [Hash] Additional options to pass to .new
    # @return [API] The API connection
    def self.new_for_domain(domain, target: :client, keep_wellknown: false, ssl: true, **params)
      domain, port = domain.split(':')
      uri = URI("http#{ssl ? 's' : ''}://#{domain}")
      well_known = nil
      target_uri = nil

      if !port.nil? && !port.empty?
        # If the domain is fully qualified according to Matrix (FQDN and port) then skip discovery
        target_uri = URI("https://#{domain}:#{port}")
      elsif target == :server
        # Attempt SRV record discovery
        target_uri = begin
                       require 'resolv'
                       resolver = Resolv::DNS.new
                       resolver.getresource("_matrix._tcp.#{domain}")
                     rescue StandardError
                       nil
                     end

        if target_uri.nil?
          # Attempt .well-known discovery for server-to-server
          well_known = begin
                         data = Net::HTTP.get("https://#{domain}/.well-known/matrix/server")
                         JSON.parse(data)
                       rescue StandardError
                         nil
                       end

          target_uri = well_known['m.server'] if well_known&.key?('m.server')
        else
          target_uri = URI("https://#{target_uri.target}:#{target_uri.port}")
        end
      elsif %i[client identity].include? target
        # Attempt .well-known discovery
        well_known = begin
                       data = Net::HTTP.get("https://#{domain}/.well-known/matrix/client")
                       JSON.parse(data)
                     rescue StandardError
                       nil
                     end

        if well_known
          key = 'm.homeserver'
          key = 'm.identity_server' if target == :identity

          if well_known.key?(key) && well_known[key].key?('base_url')
            uri = URI(well_known[key]['base_url'])
            target_uri = uri
          end
        end
      end

      # Fall back to direct domain connection
      target_uri ||= URI("https://#{domain}:8448")

      params[:well_known] = well_known if keep_wellknown

      new(uri,
          params.merge(
            address: target_uri.host,
            port: target_uri.port
          ))
    end

    # Get a list of enabled protocols on the API client
    #
    # @example
    #   MatrixSdk::Api.new_for_domain('matrix.org').protocols
    #   # => [:IS, :CS]
    #
    # @return [Symbol[]] An array of enabled APIs
    def protocols
      self
        .class.included_modules
        .reject { |m| m&.name.nil? }
        .select { |m| m.name.start_with? 'MatrixSdk::Protocols::' }
        .map { |m| m.name.split('::').last.to_sym }
    end

    # Check if a protocol is enabled on the API connection
    #
    # @example Checking for identity server API support
    #   api.protocol? :IS
    #   # => false
    #
    # @param protocol [Symbol] The protocol to check
    # @return [Boolean] Is the protocol enabled
    def protocol?(protocol)
      protocols.include? protocol
    end

    # @param seconds [Numeric]
    # @return [Numeric]
    def open_timeout=(seconds)
      @http.finish if @http && @open_timeout != seconds
      @open_timeout = seconds
    end

    # @param seconds [Numeric]
    # @return [Numeric]
    def read_timeout=(seconds)
      @http.finish if @http && @read_timeout != seconds
      @read_timeout = seconds
    end

    # @param validate [Boolean]
    # @return [Boolean]
    def validate_certificate=(validate)
      # The HTTP connection needs to be reopened if this changes
      @http.finish if @http && validate != @validate_certificate
      @validate_certificate = validate
    end

    # @param hs_info [URI]
    # @return [URI]
    def homeserver=(hs_info)
      # TODO: DNS query for SRV information about HS?
      return unless hs_info.is_a? URI

      @http.finish if @http && homeserver != hs_info
      @homeserver = hs_info
    end

    # @param [URI] proxy_uri The URI for the proxy to use
    # @return [URI]
    def proxy_uri=(proxy_uri)
      proxy_uri = URI(proxy_uri.to_s) unless proxy_uri.is_a? URI

      if @http && @proxy_uri != proxy_uri
        @http.finish
        @http = nil
      end
      @proxy_uri = proxy_uri
    end

    # Perform a raw Matrix API request
    #
    # @example Simple API query
    #   api.request(:get, :client_r0, '/account/whoami')
    #   # => { :user_id => "@alice:matrix.org" }
    #
    # @example Advanced API request
    #   api.request(:post,
    #               :media_r0,
    #               '/upload',
    #               body_stream: open('./file'),
    #               headers: { 'content-type' => 'image/png' })
    #   # => { :content_uri => "mxc://example.com/AQwafuaFswefuhsfAFAgsw" }
    #
    # @param method [Symbol] The method to use, can be any of the ones under Net::HTTP
    # @param api [Symbol] The API symbol to use, :client_r0 is the current CS one
    # @param path [String] The API path to call, this is the part that comes after the API definition in the spec
    # @param options [Hash] Additional options to pass along to the request
    # @option options [Hash] :query Query parameters to set on the URL
    # @option options [Hash,String] :body The body to attach to the request, will be JSON-encoded if sent as a hash
    # @option options [IO] :body_stream A body stream to attach to the request
    # @option options [Hash] :headers Additional headers to set on the request
    # @option options [Boolean] :skip_auth (false) Skip authentication
    def request(method, api, path, **options)
      url = homeserver.dup.tap do |u|
        u.path = api_to_path(api) + path
        u.query = [u.query, URI.encode_www_form(options.fetch(:query))].flatten.compact.join('&') if options[:query]
        u.query = nil if u.query.nil? || u.query.empty?
      end
      request = Net::HTTP.const_get(method.to_s.capitalize.to_sym).new url.request_uri
      request.body = options[:body] if options.key? :body
      request.body = request.body.to_json if options.key?(:body) && !request.body.is_a?(String)
      request.body_stream = options[:body_stream] if options.key? :body_stream

      global_headers.each { |h, v| request[h] = v }
      if request.body || request.body_stream
        request.content_type = 'application/json'
        request.content_length = (request.body || request.body_stream).size
      end

      request['authorization'] = "Bearer #{access_token}" if access_token && !options.fetch(:skip_auth, false)
      if options.key? :headers
        options[:headers].each do |h, v|
          request[h.to_s.downcase] = v
        end
      end

      failures = 0
      loop do
        raise MatrixConnectionError, "Server still too busy to handle request after #{failures} attempts, try again later" if failures >= 10

        print_http(request)
        begin
          response = http.request request
        rescue EOFError => e
          logger.error 'Socket closed unexpectedly'
          raise e
        end
        print_http(response)
        data = JSON.parse(response.body, symbolize_names: true) rescue nil

        if response.is_a? Net::HTTPTooManyRequests
          raise MatrixRequestError.new_by_code(data, response.code) unless autoretry

          failures += 1
          waittime = data[:retry_after_ms] || data[:error][:retry_after_ms] || @backoff_time
          sleep(waittime.to_f / 1000.0)
          next
        end

        return MatrixSdk::Response.new self, data if response.is_a? Net::HTTPSuccess
        raise MatrixRequestError.new_by_code(data, response.code) if data

        raise MatrixConnectionError.class_by_code(response.code), response
      end
    end

    private

    def print_http(http, body: true)
      return unless logger.debug?

      if http.is_a? Net::HTTPRequest
        dir = '>'
        logger.debug "#{dir} Sending a #{http.method} request to `#{http.path}`:"
      else
        dir = '<'
        logger.debug "#{dir} Received a #{http.code} #{http.message} response:"
      end
      http.to_hash.map { |k, v| "#{k}: #{k == 'authorization' ? '[ REDACTED ]' : v.join(', ')}" }.each do |h|
        logger.debug "#{dir} #{h}"
      end
      logger.debug dir
      if body
        clean_body = JSON.parse(http.body) rescue nil if http.body
        clean_body.keys.each { |k| clean_body[k] = '[ REDACTED ]' if %w[password access_token].include?(k) }.to_json if clean_body.is_a? Hash
        clean_body = clean_body.to_s if clean_body
        logger.debug "#{dir} #{clean_body.length < 200 ? clean_body : clean_body.slice(0..200) + "... [truncated, #{clean_body.length} Bytes]"}" if clean_body
      end
    rescue StandardError => e
      logger.warn "#{e.class} occured while printing request debug; #{e.message}\n#{e.backtrace.join "\n"}"
    end

    def transaction_id
      ret = @transaction_id ||= 0
      @transaction_id = @transaction_id.succ
      ret
    end

    def api_to_path(api)
      # TODO: <api>_current / <api>_latest
      "/_matrix/#{api.to_s.split('_').join('/')}"
    end

    def http
      return @http if @http&.active?

      host = (@connection_address || homeserver.host)
      port = (@connection_port || homeserver.port)
      @http ||= if proxy_uri
                  Net::HTTP.new(host, port, proxy_uri.host, proxy_uri.port, proxy_uri.user, proxy_uri.password)
                else
                  Net::HTTP.new(host, port)
                end

      @http.open_timeout = open_timeout
      @http.read_timeout = read_timeout
      @http.use_ssl = homeserver.scheme == 'https'
      @http.verify_mode = validate_certificate ? ::OpenSSL::SSL::VERIFY_PEER : ::OpenSSL::SSL::VERIFY_NONE
      @http.start
      @http
    end
  end
end
