require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module MatrixSdk
  class Api
    attr_accessor :access_token, :device_id, :validate_certificate
    attr_reader :homeserver

    def initialize(homeserver, params = {})
      @homeserver = homeserver
      @homeserver = URI(@homeserver) unless @homeserver.is_a? URI
      @homeserver.path.sub!('/_matrix/', '/') if @homeserver.path.start_with? '/_matrix/'

      @access_token = params.fetch(:access_token, nil)
      @device_id = params.fetch(:device_id, nil)
      @validate_certificate = params.fetch(:validate_certificate, false)

      login(user: @homeserver.user, password: @homeserver.password) if @homserver.user && @homeserver.password && !@access_token && !params[:skip_login]
      @homserver.userinfo = '' unless params[:skip_login]
    end

    def api_versions
      request(:get, :client, '/versions')
    end

    def sync(params = {})
      options = {
        timeout: 30.0,
      }.merge(params).select { |k, _v|
        %i[since timeout timeout_ms filter full_state set_presence].include? k
      }

      options[:timeout] = ((options[:timeout] || 30) * 1000).to_i
      options[:timeout] = options.delete(:timeout_ms).to_i if options.key? :timeout_ms

      request(:get, :client_r0, '/sync', query: options)
    end

    def register(params = {})
      raise NotImplementedError, 'Registering is not implemented yet'
    end

    def login(params = {})
      options = {}
      options[:store_token] = params.delete(:store_token) { true }

      data = {
        type: params.delete(:login_type) { 'm.login.password' }
      }.merge params
      data[:device_id] = device_id if device_id

      request(:post, :client_r0, '/login', body: data).tap do |resp|
        @access_token = resp[:token] if resp[:token] && options[:store_token]
      end
    end

    def logout
      request(:post, :client_r0, '/logout')
    end

    def create_room(params = {})
      raise NotImplementedError, 'Creating rooms is not implemented yet'
    end

    def join_room(id_or_alias)
      request(:post, :client_r0, "/join/#{URI.escape id_or_alias}")
    end

    def whoami?
      request(:get, :client_r0, '/account/whoami')
    end

    def request(method, api, path, options = {})
      url = homeserver.dup.tap do |u|
        u.path = api_to_path(api) + path
        u.query = [u.query, options[:query].map {|k,v| "#{k}#{"=#{v}" unless v.nil?}"}].flatten.join('&') if options[:query]
      end
      request = Net::HTTP.const_get(method.to_s.capitalize.to_sym).new url.request_uri
      request.body = options[:body] if options.key? :body
      request.body = request.body.to_json unless request.body.is_a? String
      request.body_stream = options[:body_stream] if options.key? :body_stream

      request.content_type = 'application/json' if request.body || request.body_stream

      request['authorization'] = "Bearer #{access_token}" if access_token
      request['user-agent'] = user_agent
      options[:headers].each do |h, v|
        request[h.to_s.downcase] = v
      end if options.key? :headers

      response = http.request request
      data = JSON.parse response.body, symbolize_names: true

      return data if response.kind_of? Net::HTTPSuccess
      raise MatrixError, data, response.code
    end

    private

    def api_to_path(api)
      # TODO: <api>_current / <api>_latest
      "/_matrix/#{api.to_s.split('_').join('/')}"
    end

    def http
      @http ||= (
        opts = { }
        opts[:use_ssl] = true if homeserver.scheme == 'https'
        opts[:verify_mode] = ::OpenSSL::SSL::VERIFY_NONE unless validate_certificate
        Net::HTTP.start homeserver.host, homeserver.port, opts
      )
    end

    def user_agent
      "Ruby Matrix SDK v#{MatrixSdk::VERSION}"
    end
  end
end
