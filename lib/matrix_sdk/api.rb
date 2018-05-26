require 'matrix_sdk'

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module MatrixSdk
  class Api
    attr_accessor :access_token, :device_id
    attr_reader :homeserver, :validate_certificate

    ignore_inspect :access_token

    def initialize(homeserver, params = {})
      @homeserver = homeserver
      @homeserver = URI.parse("#{'https://' unless @homeserver.start_with? 'http'}#{@homeserver}") unless @homeserver.is_a? URI
      if @homeserver.path.end_with? '_matrix/'
        @homeserver.path = begin
          split = @homeserver.path.rpartition '_matrix/'
          (split[(split.find_index '_matrix/')] = '/') rescue nil
          split.join
        end
      end
      raise 'Please use the base URL for your HS (without /_matrix/)' if @homeserver.path.include? '/_matrix/'

      @access_token = params.fetch(:access_token, nil)
      @device_id = params.fetch(:device_id, nil)
      @validate_certificate = params.fetch(:validate_certificate, false)
      @transaction_id = params.fetch(:transaction_id, 0)
      @backoff_time = params.fetch(:backoff_time, 5000)

      login(user: @homeserver.user, password: @homeserver.password) if @homeserver.user && @homeserver.password && !@access_token && !params[:skip_login]
      @homeserver.userinfo = '' unless params[:skip_login]
    end

    def logger
      @logger ||= Logging.logger[self.class.name]
    end

    def validate_certificate=(validate)
      # The HTTP connection needs to be reopened if this changes
      @http.finish if @http && validate != @validate_certificate
      @validate_certificate = validate
    end

    def homeserver=(hs_info)
      # TODO: DNS query for SRV information about HS?
      return unless hs_info.is_a? URI
      @http.finish if @http
      @homeserver = hs_info
    end

    def api_versions
      request(:get, :client, '/versions')
    end

    def sync(params = {})
      query = {
        timeout: 30.0
      }.merge(params).select do |k, _v|
        %i[since timeout filter full_state set_presence].include? k
      end

      query[:timeout] = ((query[:timeout] || 30) * 1000).to_i
      query[:timeout] = params.delete(:timeout_ms).to_i if params.key? :timeout_ms

      request(:get, :client_r0, '/sync', query: query)
    end

    def register(params = {})
      kind = params.delete(:kind) { 'user' }

      request(:post, :client_r0, '/register', body: params, query: { kind: kind })
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
      content = {
        visibility: params.fetch(:visibility, :public)
      }
      content[:room_alias_name] = params[:room_alias] if params[:room_alias]
      content[:invite] = [params[:invite]].flatten if params[:invite]

      request(:post, :client_r0, '/createRoom', content)
    end

    def join_room(id_or_alias)
      request(:post, :client_r0, "/join/#{CGI.escape id_or_alias}")
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
      content[:reason] = params[:reason] if params[:reason]

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

    def get_room_messages(room_id, token, direction, params = {})
      query = {
        roomId: room_id,
        from: token,
        dir: direction,
        limit: params.fetch(:limit, 10)
      }
      query[:to] = params[:to] if params.key? :to

      request(:get, :client_r0, "/rooms/#{room_id}/messages", query: query)
    end

    def get_room_name(room_id)
      request(:get, :client_r0, "/rooms/#{room_id}/state/m.room.name")
    end

    def set_room_name(room_id, name, params = {})
      content = {
        name: name
      }
      send_state_event(room_id, 'm.room.name', content, params)
    end

    def get_room_topic(room_id)
      request(:get, :client_r0, "/rooms/#{room_id}/state/m.room.topic")
    end

    def set_room_topic(room_id, topic, params = {})
      content = {
        topic: topic
      }
      send_state_event(room_id, 'm.room.topic', content, params)
    end

    def get_power_levels(room_id)
      request(:get, :client_r0, "/rooms/#{room_id}/state/m.room.power_levels")
    end

    def set_power_levels(room_id, content)
      content[:events] = {} unless content.key? :events
      send_state_event(room_id, 'm.room.power_levels', content)
    end

    def leave_room(room_id)
      request(:post, :client_r0, "/rooms/#{room_id}/leave")
    end

    def forget_room(room_id)
      request(:post, :client_r0, "/rooms/#{room_id}/forget")
    end

    def invite_user(room_id, user_id)
      content = {
        user_id: user_id
      }
      request(:post, :client_r0, "/rooms/#{room_id}/invite", body: content)
    end

    def kick_user(room_id, user_id, params = {})
      set_membership(room_id, user_id, 'leave', params)
    end

    def get_membership(room_id, user_id)
      request(:get, :client_r0, "/rooms/#{room_id}/state/m.room.member/#{user_id}")
    end

    def set_membership(room_id, user_id, membership, params = {})
      content = {
        membership: membership,
        reason: params.delete(:reason) { '' }
      }
      content[:displayname] = params.delete(:displayname) if params.key? :displayname
      content[:avatar_url] = params.delete(:avatar_url) if params.key? :avatar_url

      send_state_event(room_id, 'm.room.member', content, params.merge(state_key: user_id))
    end

    def ban_user(room_id, user_id, params = {})
      content = {
        user_id: user_id,
        reason: params[:reason] || ''
      }
      request(:post, :client_r0, "/rooms/#{room_id}/ban", body: content)
    end

    def unban_user(room_id, user_id)
      content = {
        user_id: user_id
      }
      request(:post, :client_r0, "/rooms/#{room_id}/unban", body: content)
    end

    def get_user_tags(user_id, room_id)
      request(:get, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags")
    end

    def remove_user_tag(user_id, room_id, tag)
      request(:delete, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags/#{tag}")
    end

    def add_user_tag(user_id, room_id, tag, params = {})
      if params[:body]
        content = params[:body]
      else
        content = {}
        content[:order] = params[:order] if params.key? :order
      end
      request(:put, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags/#{tag}", body: content)
    end

    def get_account_data(user_id, type)
      request(:get, :client_r0, "/user/#{user_id}/account_data/#{type}")
    end

    def set_account_data(user_id, type, account_data)
      request(:put, :client_r0, "/user/#{user_id}/account_data/#{type}", body: account_data)
    end

    def get_room_account_data(user_id, room_id, type)
      request(:get, :client_r0, "/user/#{user_id}/rooms/#{room_id}/account_data/#{type}")
    end

    def set_room_account_data(user_id, room_id, type, account_data)
      request(:put, :client_r0, "/user/#{user_id}/rooms/#{room_id}/account_data/#{type}", body: account_data)
    end

    def get_room_state(room_id)
      request(:get, :client_r0, "/rooms/#{room_id}/state")
    end

    def get_filter(user_id, filter_id)
      request(:get, :client_r0, "/user/#{user_id}/filter/#{filter_id}")
    end

    def create_filter(user_id, filter_params)
      request(:post, :client_r0, "/user/#{user_id}/filter", body: filter_params)
    end

    def media_upload(content, content_type)
      request(:post, :media_r0, '/upload', body: content, headers: { 'content-type' => content_type })
    end

    def get_display_name(user_id)
      request(:get, :client_r0, "/profile/#{user_id}/displayname")
    end

    def set_display_name(user_id, display_name)
      content = {
        display_name: display_name
      }
      request(:put, :client_r0, "/profile/#{user_id}/displayname", body: content)
    end

    def get_avatar_url(user_id)
      request(:get, :client_r0, "/profile/#{user_id}/avatar_url")
    end

    def set_avatar_url(user_id, url)
      content = {
        avatar_url: url
      }
      request(:put, :client_r0, "/profile/#{user_id}/avatar_url", body: content)
    end

    def get_download_url(mxcurl)
      mxcurl = URI.parse(mxcurl.to_s) unless mxcurl.is_a? URI
      raise 'Not a mxc:// URL' unless mxcurl.is_a? URI::MATRIX

      homeserver.dup.tap do |u|
        u.path = "/_matrix/media/r0/download/#{mxcurl.full_path}"
      end
    end

    def get_room_id(room_alias)
      request(:get, :client_r0, "/directory/room/#{room_alias}")
    end

    def set_room_alias(room_id, room_alias)
      content = {
        room_id: room_id
      }
      request(:put, :client_r0, "/directory/room/#{room_alias}", body: content)
    end

    def remove_room_alias(room_alias)
      request(:delete, :client_r0, "/directory/room/#{room_alias}")
    end

    def get_room_members(room_id)
      request(:get, :client_r0, "/rooms/#{room_id}/members")
    end

    def set_join_rule(room_id, join_rule)
      content = {
        join_rule: join_rule
      }
      send_state_event(room_id, 'm.room.join_rules', content)
    end

    def set_guest_access(room_id, guest_access)
      # raise ArgumentError, '`guest_access` must be one of [:can_join, :forbidden]' unless %i[can_join forbidden].include? guest_access
      content = {
        guest_access: guest_access
      }
      send_state_event(room_id, 'm.room.guest_access', content)
    end

    def whoami?
      request(:get, :client_r0, '/account/whoami')
    end

    def request(method, api, path, options = {})
      url = homeserver.dup.tap do |u|
        u.path = api_to_path(api) + path
        u.query = [u.query, options[:query].map { |k, v| "#{k}#{"=#{v}" unless v.nil?}" }].flatten.reject(&:nil?).join('&') if options[:query]
        u.query = nil if u.query.nil? || u.query.empty?
      end
      request = Net::HTTP.const_get(method.to_s.capitalize.to_sym).new url.request_uri
      request.body = options[:body] if options.key? :body
      request.body = request.body.to_json if options.key?(:body) && !request.body.is_a?(String)
      request.body_stream = options[:body_stream] if options.key? :body_stream

      request.content_type = 'application/json' if request.body || request.body_stream

      request['authorization'] = "Bearer #{access_token}" if access_token
      request['user-agent'] = user_agent
      if options.key? :headers
        options[:headers].each do |h, v|
          request[h.to_s.downcase] = v
        end
      end

      failures = 0
      loop do
        raise MatrixConnectionError, "Server still too busy to handle request after #{failures} attempts, try again later" if failures >= 10

        print_http(request)
        response = http.request request
        print_http(response)
        data = JSON.parse(response.body, symbolize_names: true) rescue nil

        if response.is_a? Net::HTTPTooManyRequests
          failures += 1
          waittime = data[:retry_after_ms] || data[:error][:retry_after_ms] || @backoff_time
          sleep(waittime.to_f / 1000.0)
          next
        end

        return data if response.is_a? Net::HTTPSuccess
        raise MatrixRequestError.new(data, response.code) if data
        raise MatrixConnectionError, response
      end
    end

    private

    def print_http(http)
      return unless logger.debug?

      if http.is_a? Net::HTTPRequest
        dir = '>'
        logger.debug "#{dir} Sending a #{http.method} request to `#{http.path}`:"
      else
        dir = '<'
        logger.debug "#{dir} Received a #{http.code} #{http.message} response:"
      end
      http.to_hash.map { |k, v| "#{k}: #{k == 'authorization' ? '[redacted]' : v.join(', ')}" }.each do |h|
        logger.debug "#{dir} #{h}"
      end
      logger.debug dir
      clean_body = JSON.parse(http.body).each { |k, v| v.replace('[redacted]') if %w[password access_token].include? k }.to_json if http.body
      logger.debug "#{dir} #{clean_body.length < 200 ? clean_body : clean_body.slice(0..200) + '... [truncated]'}" if clean_body
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
      @http ||= Net::HTTP.new homeserver.host, homeserver.port
      return @http if @http.active?

      @http.use_ssl = homeserver.scheme == 'https'
      @http.verify_mode = validate_certificate ? ::OpenSSL::SSL::VERIFY_NONE : nil
      @http.start
    end

    def user_agent
      "Ruby Matrix SDK v#{MatrixSdk::VERSION}"
    end
  end
end
