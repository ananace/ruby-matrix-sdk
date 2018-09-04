require 'matrix_sdk'

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module MatrixSdk
  class Api
    USER_AGENT = "Ruby Matrix SDK v#{MatrixSdk::VERSION}".freeze
    DEFAULT_HEADERS = {
      'accept'     => 'application/json',
      'user-agent' => USER_AGENT
    }.freeze

    attr_accessor :access_token, :connection_address, :connection_port, :device_id, :autoretry, :global_headers
    attr_reader :homeserver, :validate_certificate, :read_timeout

    ignore_inspect :access_token, :logger

    # @param homeserver [String,URI] The URL to the Matrix homeserver, without the /_matrix/ part
    # @param params [Hash] Additional parameters on creation
    # @option params [String] :address The connection address to the homeserver, if different to the HS URL
    # @option params [Integer] :port The connection port to the homeserver, if different to the HS URL
    # @option params [String] :access_token The access token to use for the connection
    # @option params [String] :device_id The ID of the logged in decide to use
    # @option params [Boolean] :autoretry (true) Should requests automatically be retried in case of rate limits
    # @option params [Boolean] :validate_certificate (false) Should the connection require valid SSL certificates
    # @option params [Integer] :transaction_id (0) The starting ID for transactions
    # @option params [Numeric] :backoff_time (5000) The request backoff time in milliseconds
    # @option params [Numeric] :read_timeout (240) The timeout in seconds for reading responses
    # @option params [Hash] :global_headers Additional headers to set for all requests
    # @option params [Boolean] :skip_login Should the API skip logging in if the HS URL contains user information
    def initialize(homeserver, params = {})
      @homeserver = homeserver
      @homeserver = URI.parse("#{'https://' unless @homeserver.start_with? 'http'}#{@homeserver}") unless @homeserver.is_a? URI
      @homeserver.path.gsub!(/\/?_matrix\/?/, '') if @homeserver.path =~ /_matrix\/?$/
      raise 'Please use the base URL for your HS (without /_matrix/)' if @homeserver.path.include? '/_matrix/'

      @connection_address = params.fetch(:address, nil)
      @connection_port = params.fetch(:port, nil)
      @access_token = params.fetch(:access_token, nil)
      @device_id = params.fetch(:device_id, nil)
      @autoretry = params.fetch(:autoretry, true)
      @validate_certificate = params.fetch(:validate_certificate, false)
      @transaction_id = params.fetch(:transaction_id, 0)
      @backoff_time = params.fetch(:backoff_time, 5000)
      @read_timeout = params.fetch(:read_timeout, 240)
      @global_headers = DEFAULT_HEADERS.dup
      @global_headers.merge!(params.fetch(:global_headers)) if params.key? :global_headers

      login(user: @homeserver.user, password: @homeserver.password) if @homeserver.user && @homeserver.password && !@access_token && !params[:skip_login]
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
    # @param params [Hash] Additional options to pass to .new
    # @return [API] The API connection
    def self.new_for_domain(domain, params = {})
      # Attempt SRV record discovery
      srv = if domain.include? ':'
              addr, port = domain.split ':'
              Resolv::DNS::Resource::IN::SRV.new 10, 1, port.to_i, addr
            else
              require 'resolv'
              resolver = Resolv::DNS.new
              begin
                resolver.getresource("_matrix._tcp.#{domain}")
              rescue Resolv::ResolvError
                nil
              end
            end

      # Attempt .well-known discovery
      if srv.nil?
        well_known = begin
                       data = Net::HTTP.get("https://#{domain}/.well-known/matrix/client")
                       JSON.parse(data)
                     rescue
                       nil
                     end

        return new(well_known['m.homeserver']['base_url']) if well_known &&
                                                              well_known.key?('m.homeserver') &&
                                                              well_known['m.homerserver'].key?('base_url')
      end

      # Fall back to A record on domain
      srv ||= Resolv::DNS::Resource::IN::SRV.new 10, 1, 8448, domain

      domain = domain.split(':').first if domain.include? ':'
      new("https://#{domain}",
          params.merge(
            address: srv.target.to_s,
            port: srv.port
          ))
    end

    # Gets the logger for the API
    # @return [Logging::Logger] The API-scope logger
    def logger
      @logger ||= Logging.logger[self]
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
      @http.finish if @http
      @homeserver = hs_info
    end

    # Gets the available client API versions
    # @return [Array]
    def client_api_versions
      @client_api_versions ||= request(:get, :client, '/versions').versions.tap do |vers|
        vers.instance_eval <<-'CODE', __FILE__, __LINE__ + 1
          def latest
            latest
          end
        CODE
      end
    end

    # Gets the list of available unstable client API features
    # @return [Array]
    def client_api_unstable_features
      @client_api_unstable_features ||= request(:get, :client, '/versions').unstable_features.tap do |vers|
        vers.instance_eval <<-'CODE', __FILE__, __LINE__ + 1
          def has?(feature)
            fetch(feature, nil)
          end
        CODE
      end
    end

    # Gets the server version
    # @note This uses the unstable federation/v1 API
    def server_version
      Response.new(self, request(:get, :federation_v1, '/version').server).tap do |resp|
        resp.instance_eval <<-'CODE', __FILE__, __LINE__ + 1
          def to_s
            "#{name} #{version}"
          end
        CODE
      end
    end

    # Runs the client API /sync method
    # @param params [Hash] The sync options to use
    # @option params [Numeric] :timeout (30.0) The timeout in seconds for the sync
    # @option params :since The value of the batch token to base the sync from
    # @option params [String,Hash] :filter The filter to use on the sync
    # @option params [Boolean] :full_state Should the sync include the full state
    # @option params [Boolean] :set_presence Should the sync set the user status to online
    # @return [Response]
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-sync
    #      For more information on the parameters and what they mean
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

    # Registers a user using the client API /register endpoint
    #
    # @example Regular user registration and login
    #   api.register(username: 'example', password: 'NotARealPass')
    #   # => { user_id: '@example:matrix.org', access_token: '...', home_server: 'matrix.org', device_id: 'ABCD123' }
    #   api.whoami?
    #   # => { user_id: '@example:matrix.org' }
    #
    # @param params [Hash] The registration information, all not handled by Ruby will be passed as JSON in the body
    # @option params [String,Symbol] :kind ('user') The kind of registration to use
    # @option params [Boolean] :store_token (true) Should the resulting access token be stored for the API
    # @option params [Boolean] :store_device_id (store_token value) Should the resulting device ID be stored for the API
    # @return [Response]
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-register
    #      For options that are permitted in this call
    def register(params = {})
      kind = params.delete(:kind) { 'user' }
      store_token = params.delete(:store_token) { true }
      store_device_id = params.delete(:store_device_id) { store_token }

      request(:post, :client_r0, '/register', body: params, query: { kind: kind }).tap do |resp|
        @access_token = resp.token if resp.key?(:token) && store_token
        @device_id = resp.device_id if resp.key?(:device_id) && store_device_id
      end
    end

    # Logs in using the client API /login endpoint, and optionally stores the resulting access for API usage
    #
    # @example Logging in with username and password
    #   api.login(user: 'example', password: 'NotARealPass')
    #   # => { user_id: '@example:matrix.org', access_token: '...', home_server: 'matrix.org', device_id: 'ABCD123' }
    #   api.whoami?
    #   # => { user_id: '@example:matrix.org' }
    #
    # @example Advanced login, without storing details
    #   api.whoami?
    #   # => { user_id: '@example:matrix.org' }
    #   api.login(medium: 'email', address: 'someone@somewhere.net', password: '...', store_token: false)
    #   # => { user_id: '@someone:matrix.org', access_token: ...
    #   api.whoami?.user_id
    #   # => '@example:matrix.org'
    #
    # @param params [Hash] The login information to use, along with options for said log in
    # @option params [Boolean] :store_token (true) Should the resulting access token be stored for the API
    # @option params [Boolean] :store_device_id (store_token value) Should the resulting device ID be stored for the API
    # @option params [String] :login_type ('m.login.password') The type of login to attempt
    # @option params [String] :initial_device_display_name (USER_AGENT) The device display name to specify for this login attempt
    # @option params [String] :device_id The device ID to set on the login
    # @return [Response] A response hash with the parameters :user_id, :access_token, :home_server, and :device_id.
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-login
    #      The Matrix Spec, for more information about the call and response
    def login(params = {})
      options = {}
      options[:store_token] = params.delete(:store_token) { true }
      options[:store_device_id] = params.delete(:store_device_id) { options[:store_token] }

      data = {
        type: params.delete(:login_type) { 'm.login.password' },
        initial_device_display_name: params.delete(:initial_device_display_name) { USER_AGENT }
      }.merge params
      data[:device_id] = device_id if device_id

      request(:post, :client_r0, '/login', body: data).tap do |resp|
        @access_token = resp.token if resp.key?(:token) && options[:store_token]
        @device_id = resp.device_id if resp.key?(:device_id) && options[:store_device_id]
      end
    end

    # Logs out the currently logged in user
    # @return [Response] An empty response if the logout was successful
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-logout
    #      The Matrix Spec, for more information about the call and response
    def logout
      request(:post, :client_r0, '/logout')
    end

    # Creates a new room
    # @param params [Hash] The room creation details
    # @option params [Symbol] :visibility (:public) The room visibility
    # @option params [String] :room_alias A room alias to apply on creation
    # @option params [Boolean] :invite Should the room be created invite-only
    # @return [Response] A response hash with ...
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-createroom
    #      The Matrix Spec, for more information about the call and response
    def create_room(params = {})
      content = {
        visibility: params.fetch(:visibility, :public)
      }
      content[:room_alias_name] = params[:room_alias] if params[:room_alias]
      content[:invite] = [params[:invite]].flatten if params[:invite]

      request(:post, :client_r0, '/createRoom', content)
    end

    # Joins a room
    # @param id_or_alias [MXID,String] The room ID or Alias to join
    # @return [Response] A response hash with the parameter :room_id
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#post-matrix-client-r0-join-roomidoralias
    #      The Matrix Spec, for more information about the call and response
    def join_room(id_or_alias)
      # id_or_alias = MXID.new id_or_alias.to_s unless id_or_alias.is_a? MXID
      # raise ArgumentError, 'Not a room ID or alias' unless id_or_alias.room?

      id_or_alias = CGI.escape id_or_alias.to_s

      request(:post, :client_r0, "/join/#{id_or_alias}")
    end

    # Sends a state event to a room
    # @param room_id [MXID,String] The room ID to send the state event to
    # @param event_type [String] The event type to send
    # @param content [Hash] The contents of the state event
    # @param params [Hash] Options for the request
    # @option params [Integer] :timestamp The timestamp when the event was created, only used for AS events
    # @option params [String] :state_key The state key of the event, if there is one
    # @return [Response] A response hash with the parameter :event_id
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#put-matrix-client-r0-rooms-roomid-state-eventtype-statekey
    #      https://matrix.org/docs/spec/client_server/r0.3.0.html#put-matrix-client-r0-rooms-roomid-state-eventtype
    #      The Matrix Spec, for more information about the call and response
    def send_state_event(room_id, event_type, content, params = {})
      query = {}
      query[:ts] = params[:timestamp].to_i if params.key? :timestamp

      room_id = CGI.escape room_id.to_s
      event_type = CGI.escape event_type.to_s
      state_key = CGI.escape params[:state_key].to_s if params.key? :state_key

      request(:put, :client_r0, "/rooms/#{room_id}/state/#{event_type}#{"/#{state_key}" unless state_key.nil?}", body: content, query: query)
    end

    # Sends a message event to a room
    # @param room_id [MXID,String] The room ID to send the message event to
    # @param event_type [String] The event type of the message
    # @param content [Hash] The contents of the message
    # @param params [Hash] Options for the request
    # @option params [Integer] :timestamp The timestamp when the event was created, only used for AS events
    # @option params [Integer] :txn_id The ID of the transaction, or automatically generated
    # @return [Response] A response hash with the parameter :event_id
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#put-matrix-client-r0-rooms-roomid-send-eventtype-txnid
    #      The Matrix Spec, for more information about the call and response
    def send_message_event(room_id, event_type, content, params = {})
      query = {}
      query[:ts] = params[:timestamp].to_i if params.key? :timestamp

      txn_id = transaction_id
      txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

      room_id = CGI.escape room_id.to_s
      event_type = CGI.escape event_type.to_s
      txn_id = CGI.escape txn_id.to_s

      request(:put, :client_r0, "/rooms/#{room_id}/send/#{event_type}/#{txn_id}", body: content, query: query)
    end

    # Redact an event in a room
    # @param room_id [MXID,String] The room ID to send the message event to
    # @param event_id [String] The event ID of the event to redact
    # @param params [Hash] Options for the request
    # @option params [Integer] :timestamp The timestamp when the event was created, only used for AS events
    # @option params [String] :reason The reason for the redaction
    # @option params [Integer] :txn_id The ID of the transaction, or automatically generated
    # @return [Response] A response hash with the parameter :event_id
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#put-matrix-client-r0-rooms-roomid-redact-eventid-txnid
    #      The Matrix Spec, for more information about the call and response
    def redact_event(room_id, event_id, params = {})
      query = {}
      query[:ts] = params[:timestamp].to_i if params.key? :timestamp

      content = {}
      content[:reason] = params[:reason] if params[:reason]

      txn_id = transaction_id
      txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

      room_id = CGI.escape room_id.to_s
      event_id = CGI.escape event_id.to_s
      txn_id = CGI.escape txn_id.to_s

      request(:put, :client_r0, "/rooms/#{room_id}/redact/#{event_id}/#{txn_id}", body: content, query: query)
    end

    # Send a content message to a room
    #
    # @example Sending an image to a room
    #   send_content('!abcd123:localhost',
    #                'mxc://localhost/1234567',
    #                'An image of a cat',
    #                'm.image',
    #                extra_information: {
    #                  h: 128,
    #                  w: 128,
    #                  mimetype: 'image/png',
    #                  size: 1024
    #                })
    #
    # @example Sending a file to a room
    #   send_content('!example:localhost',
    #                'mxc://localhost/fileurl',
    #                'Contract.pdf',
    #                'm.file',
    #                extra_content: {
    #                  filename: 'contract.pdf'
    #                },
    #                extra_information: {
    #                  mimetype: 'application/pdf',
    #                  size: 96674
    #                })
    #
    # @param room_id [MXID,String] The room ID to send the content to
    # @param url [URI,String] The URL to the content
    # @param name [String] The name of the content
    # @param msg_type [String] The message type of the content
    # @param params [Hash] Options for the request
    # @option params [Hash] :extra_information ({}) Extra information for the content
    # @option params [Hash] :extra_content Extra data to insert into the content hash
    # @return [Response] A response hash with the parameter :event_id
    # @see send_message_event For more information on the underlying call
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-image
    #      https://matrix.org/docs/spec/client_server/r0.3.0.html#m-file
    #      https://matrix.org/docs/spec/client_server/r0.3.0.html#m-video
    #      https://matrix.org/docs/spec/client_server/r0.3.0.html#m-audio
    #      The Matrix Spec, for more information about the call and response
    def send_content(room_id, url, name, msg_type, params = {})
      content = {
        url: url,
        msgtype: msg_type,
        body: name,
        info: params.delete(:extra_information) { {} }
      }
      content.merge!(params.fetch(:extra_content)) if params.key? :extra_content

      send_message_event(room_id, 'm.room.message', content, params)
    end

    # Send a geographic location to a room
    #
    # @param room_id [MXID,String] The room ID to send the location to
    # @param geo_uri [URI,String] The geographical URI to send
    # @param name [String] The name of the location
    # @param params [Hash] Options for the request
    # @option params [Hash] :extra_information ({}) Extra information for the location
    # @option params [URI,String] :thumbnail_url The URL to a thumbnail of the location
    # @option params [Hash] :thumbnail_info Image information about the location thumbnail
    # @return [Response] A response hash with the parameter :event_id
    # @see send_message_event For more information on the underlying call
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-location
    #      The Matrix Spec, for more information about the call and response
    def send_location(room_id, geo_uri, name, params = {})
      content = {
        geo_uri: geo_uri,
        msgtype: 'm.location',
        body: name,
        info: params.delete(:extra_information) { {} }
      }
      content[:info][:thumbnail_url] = params.delete(:thumbnail_url) if params.key? :thumbnail_url
      content[:info][:thumbnail_info] = params.delete(:thumbnail_info) if params.key? :thumbnail_info

      send_message_event(room_id, 'm.room.message', content, params)
    end

    # Send a plaintext message to a room
    #
    # @param room_id [MXID,String] The room ID to send the message to
    # @param message [String] The message to send
    # @param params [Hash] Options for the request
    # @option params [String] :msg_type ('m.text') The message type to send
    # @return [Response] A response hash with the parameter :event_id
    # @see send_message_event For more information on the underlying call
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-text
    #      The Matrix Spec, for more information about the call and response
    def send_message(room_id, message, params = {})
      content = {
        msgtype: params.delete(:msg_type) { 'm.text' },
        body: message
      }
      send_message_event(room_id, 'm.room.message', content, params)
    end

    # Send a plaintext emote to a room
    #
    # @param room_id [MXID,String] The room ID to send the message to
    # @param emote [String] The emote to send
    # @param params [Hash] Options for the request
    # @option params [String] :msg_type ('m.emote') The message type to send
    # @return [Response] A response hash with the parameter :event_id
    # @see send_message_event For more information on the underlying call
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-emote
    #      The Matrix Spec, for more information about the call and response
    def send_emote(room_id, emote, params = {})
      content = {
        msgtype: params.delete(:msg_type) { 'm.emote' },
        body: emote
      }
      send_message_event(room_id, 'm.room.message', content, params)
    end

    # Send a plaintext notice to a room
    #
    # @param room_id [MXID,String] The room ID to send the message to
    # @param notice [String] The notice to send
    # @param params [Hash] Options for the request
    # @option params [String] :msg_type ('m.notice') The message type to send
    # @return [Response] A response hash with the parameter :event_id
    # @see send_message_event For more information on the underlying call
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-notice
    #      The Matrix Spec, for more information about the call and response
    def send_notice(room_id, notice, params = {})
      content = {
        msgtype: params.delete(:msg_type) { 'm.notice' },
        body: notice
      }
      send_message_event(room_id, 'm.room.message', content, params)
    end

    # Retrieve additional messages in a room
    #
    # @param room_id [MXID,String] The room ID to retrieve messages for
    # @param token [String] The token to start retrieving from, can be from a sync or from an earlier get_room_messages call
    # @param direction [:b,:f] The direction to retrieve messages
    # @param params [Hash] Additional options for the request
    # @option params [Integer] :limit (10) The limit of messages to retrieve
    # @option params [String] :to A token to limit retrieval to
    # @option params [String] :filter A filter to limit the retrieval to
    # @return [Response] A response hash with the message information containing :start, :end, and :chunk fields
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-rooms-roomid-messages
    #      The Matrix Spec, for more information about the call and response
    def get_room_messages(room_id, token, direction, params = {})
      query = {
        roomId: room_id,
        from: token,
        dir: direction,
        limit: params.fetch(:limit, 10)
      }
      query[:to] = params[:to] if params.key? :to
      query[:filter] = params.fetch(:filter) if params.key? :filter

      room_id = CGI.escape room_id.to_s

      request(:get, :client_r0, "/rooms/#{room_id}/messages", query: query)
    end

    # Reads the latest instance of a room state event
    #
    # @param room_id [MXID,String] The room ID to read from
    # @param state_type [String] The state type to read
    # @return [Response] A response hash with the contents of the state event
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-rooms-roomid-state-eventtype
    #      The Matrix Spec, for more information about the call and response
    def get_room_state(room_id, state_type)
      room_id = CGI.escape room_id.to_s
      state_type = CGI.escape state_type.to_s

      request(:get, :client_r0, "/rooms/#{room_id}/state/#{state_type}")
    end

    # Gets the display name of a room
    #
    # @param room_id [MXID,String] The room ID to look up
    # @return [Response] A response hash with the parameter :name
    # @see get_room_state
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-room-name
    #      The Matrix Spec, for more information about the event and data
    def get_room_name(room_id)
      get_room_state(room_id, 'm.room.name')
    end

    def set_room_name(room_id, name, params = {})
      content = {
        name: name
      }
      send_state_event(room_id, 'm.room.name', content, params)
    end

    def get_room_topic(room_id)
      get_room_state(room_id, 'm.room.topic')
    end

    def set_room_topic(room_id, topic, params = {})
      content = {
        topic: topic
      }
      send_state_event(room_id, 'm.room.topic', content, params)
    end

    def get_power_levels(room_id)
      get_room_state(room_id, 'm.room.power_levels')
    end

    def set_power_levels(room_id, content)
      content[:events] = {} unless content.key? :events
      send_state_event(room_id, 'm.room.power_levels', content)
    end

    def leave_room(room_id)
      room_id = CGI.escape room_id.to_s

      request(:post, :client_r0, "/rooms/#{room_id}/leave")
    end

    def forget_room(room_id)
      room_id = CGI.escape room_id.to_s

      request(:post, :client_r0, "/rooms/#{room_id}/forget")
    end

    def invite_user(room_id, user_id)
      content = {
        user_id: user_id
      }

      room_id = CGI.escape room_id.to_s

      request(:post, :client_r0, "/rooms/#{room_id}/invite", body: content)
    end

    def kick_user(room_id, user_id, params = {})
      set_membership(room_id, user_id, 'leave', params)
    end

    def get_membership(room_id, user_id)
      room_id = CGI.escape room_id.to_s
      user_id = CGI.escape user_id.to_s

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

      room_id = CGI.escape room_id.to_s

      request(:post, :client_r0, "/rooms/#{room_id}/ban", body: content)
    end

    def unban_user(room_id, user_id)
      content = {
        user_id: user_id
      }

      room_id = CGI.escape room_id.to_s

      request(:post, :client_r0, "/rooms/#{room_id}/unban", body: content)
    end

    def get_user_tags(user_id, room_id)
      room_id = CGI.escape room_id.to_s
      user_id = CGI.escape user_id.to_s

      request(:get, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags")
    end

    def remove_user_tag(user_id, room_id, tag)
      room_id = CGI.escape room_id.to_s
      user_id = CGI.escape user_id.to_s
      tag = CGI.escape tag.to_s

      request(:delete, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags/#{tag}")
    end

    def add_user_tag(user_id, room_id, tag, params = {})
      if params[:body]
        content = params[:body]
      else
        content = {}
        content[:order] = params[:order] if params.key? :order
      end

      room_id = CGI.escape room_id.to_s
      user_id = CGI.escape user_id.to_s
      tag = CGI.escape tag.to_s

      request(:put, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags/#{tag}", body: content)
    end

    # def get_account_data(user_id, type)
    #   request(:get, :client_r0, "/user/#{user_id}/account_data/#{type}")
    # end

    def set_account_data(user_id, type_key, account_data)
      user_id = CGI.escape user_id.to_s
      type_key = CGI.escape type_key.to_s

      request(:put, :client_r0, "/user/#{user_id}/account_data/#{type_key}", body: account_data)
    end

    # def get_room_account_data(user_id, room_id, type)
    #   request(:get, :client_r0, "/user/#{user_id}/rooms/#{room_id}/account_data/#{type}")
    # end

    def set_room_account_data(user_id, room_id, type_key, account_data)
      user_id = CGI.escape user_id.to_s
      room_id = CGI.escape room_id.to_s
      type_key = CGI.escape type_key.to_s

      request(:put, :client_r0, "/user/#{user_id}/rooms/#{room_id}/account_data/#{type_key}", body: account_data)
    end

    def get_filter(user_id, filter_id)
      user_id = CGI.escape user_id.to_s
      filter_id = CGI.escape filter_id.to_s

      request(:get, :client_r0, "/user/#{user_id}/filter/#{filter_id}")
    end

    def create_filter(user_id, filter_params)
      user_id = CGI.escape user_id.to_s

      request(:post, :client_r0, "/user/#{user_id}/filter", body: filter_params)
    end

    def media_upload(content, content_type)
      request(:post, :media_r0, '/upload', body: content, headers: { 'content-type' => content_type })
    end

    def get_display_name(user_id)
      user_id = CGI.escape user_id.to_s

      request(:get, :client_r0, "/profile/#{user_id}/displayname")
    end

    def set_display_name(user_id, display_name)
      content = {
        displayname: display_name
      }

      user_id = CGI.escape user_id.to_s

      request(:put, :client_r0, "/profile/#{user_id}/displayname", body: content)
    end

    def get_avatar_url(user_id)
      user_id = CGI.escape user_id.to_s

      request(:get, :client_r0, "/profile/#{user_id}/avatar_url")
    end

    def set_avatar_url(user_id, url)
      content = {
        avatar_url: url
      }

      user_id = CGI.escape user_id.to_s

      request(:put, :client_r0, "/profile/#{user_id}/avatar_url", body: content)
    end

    def get_download_url(mxcurl)
      mxcurl = URI.parse(mxcurl.to_s) unless mxcurl.is_a? URI
      raise 'Not a mxc:// URL' unless mxcurl.is_a? URI::MATRIX

      homeserver.dup.tap do |u|
        full_path = CGI.escape mxcurl.full_path.to_s
        u.path = "/_matrix/media/r0/download/#{full_path}"
      end
    end

    def get_room_id(room_alias)
      room_alias = CGI.escape room_alias.to_s

      request(:get, :client_r0, "/directory/room/#{room_alias}")
    end

    def set_room_alias(room_id, room_alias)
      content = {
        room_id: room_id
      }

      room_alias = CGI.escape room_alias.to_s

      request(:put, :client_r0, "/directory/room/#{room_alias}", body: content)
    end

    def remove_room_alias(room_alias)
      room_alias = CGI.escape room_alias.to_s

      request(:delete, :client_r0, "/directory/room/#{room_alias}")
    end

    def get_room_members(room_id)
      room_id = CGI.escape room_id.to_s

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

      request['authorization'] = "Bearer #{access_token}" if access_token
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
          raise MatrixRequestError.new(data, response.code) unless autoretry
          failures += 1
          waittime = data[:retry_after_ms] || data[:error][:retry_after_ms] || @backoff_time
          sleep(waittime.to_f / 1000.0)
          next
        end

        return MatrixSdk::Response.new self, data if response.is_a? Net::HTTPSuccess
        raise MatrixRequestError.new(data, response.code) if data
        raise MatrixConnectionError.class_by_code(response.code), response
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
      http.to_hash.map { |k, v| "#{k}: #{k == 'authorization' ? '[ REDACTED ]' : v.join(', ')}" }.each do |h|
        logger.debug "#{dir} #{h}"
      end
      logger.debug dir
      clean_body = JSON.parse(http.body) rescue nil if http.body
      clean_body.keys.each { |k| clean_body[k] = '[ REDACTED ]' if %w[password access_token].include?(k) }.to_json if clean_body
      logger.debug "#{dir} #{clean_body.length < 200 ? clean_body : clean_body.slice(0..200) + "... [truncated, #{clean_body.length} Bytes]"}" if clean_body
    rescue StandardError => ex
      logger.warn "#{ex.class} occured while printing request debug; #{ex.message}\n#{ex.backtrace.join "\n"}"
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
      @http ||= Net::HTTP.new (@connection_address || homeserver.host), (@connection_port || homeserver.port)
      return @http if @http.active?

      @http.read_timeout = read_timeout
      @http.use_ssl = homeserver.scheme == 'https'
      @http.verify_mode = validate_certificate ? ::OpenSSL::SSL::VERIFY_NONE : nil
      @http.start
    end
  end
end
