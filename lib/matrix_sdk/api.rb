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
      @transaction_id = params.fetch(:transaction_id, 0)

      login(user: @homeserver.user, password: @homeserver.password) if @homserver.user && @homeserver.password && !@access_token && !params[:skip_login]
      @homserver.userinfo = '' unless params[:skip_login]
    end

    def api_versions
      request(:get, :client, '/versions')
    end

    def sync(params = {})
      query = {
        timeout: 30.0,
      }.merge(params).select { |k, _v|
        %i[since timeout filter full_state set_presence].include? k
      }

      query[:timeout] = ((query[:timeout] || 30) * 1000).to_i
      query[:timeout] = params.delete(:timeout_ms).to_i if params.key? :timeout_ms

      request(:get, :client_r0, '/sync', query: query)
    end

    def register(params = {})
      raise NotImplementedError, 'Registering is not implemented yet'
    end

    def login(params = {})
      options = {}
      options[:store_token] = params.delete(:store_token) { true }
      options[:store_device_id] = params.delete(:store_device_id) { true }

      data = {
        type: params.delete(:login_type) { 'm.login.password' },
        initial_device_display_name: params.delete(:initial_device_display_name) { user_agent }
      }.merge params
      data[:device_id] = device_id if device_id

      request(:post, :client_r0, '/login', body: data).tap do |resp|
        @access_token = resp[:token] if resp[:token] && options[:store_token]
        @device_id = resp[:device_id] if resp[:device_id] && options[:store_device_id]
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

    def send_state_event(room_id, event_type, content, params = {})
      query = {}
      query[:ts] = params[:timestamp].to_i if params.key? :timestamp

      request(:put, :client_r0, "/rooms/#{room_id}/state/#{event_type}#{"/#{params[:state_key]}" if params.key? :state_key}", body: content, query: query)
    end

    def send_message_event(room_id, event_type, content, params = {})
      query = {}
      query[:ts] = params[:timestamp].to_i if params.key? :timestamp

      txn_id = transaction_id
      txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

      request(:put, :client_r0, "/rooms/#{room_id}/send/#{event_type}/#{txn_id}", body: content, query: query)
    end

    def redact_event(room_id, event_type, params = {})
      query = {}
      query[:ts] = params[:timestamp].to_i if params.key? :timestamp
      
      content = {}
      content[:reason] = params[:reason] if params.key? :reason

      txn_id = transaction_id
      txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

      request(:put, :client_r0, "/rooms/#{room_id}/redact/#{event_type}/#{txn_id}", body: content, query: query)
    end

    def send_content(room_id, url, name, msg_type, params = {})
      content = {
        url: url,
        msgtype: msg_type,
        body: name,
        info: params.delete(:extra_information) { {} }
      }

      send_message_event(room_id, 'm.room.message', content, params)
    end

    def send_location(room_id, geo_uri, name, params = {})
      content = {
        geo_uri: geo_uri,
        msgtype: 'm.location',
        body: name
      }
      content[:thumbnail_url] = params.delete(:thumbnail_url) if params.key? :thumbnail_url
      content[:thumbnail_info] = params.delete(:thumbnail_info) if params.key? :thumbnail_info

      send_message_event(room_id, 'm.room.message', content, params)
    end

    def send_message(room_id, message, params = {})
      content = {
        msgtype: params.delete(:msg_type) { 'm.text' },
        body: message
      }
      send_message_event(room_id, 'm.room.message', content, params)
    end

    def send_emote(room_id, emote, params = {})
      content = {
        msgtype: params.delete(:msg_type) { 'm.emote' },
        body: emote
      }
      send_message_event(room_id, 'm.room.message', content, params)
    end

    def send_notice(room_id, notice, params = {})
      content = {
        msgtype: params.delete(:msg_type) { 'm.notice' },
        body: notice
      }
      send_message_event(room_id, 'm.room.message', content, params)
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
