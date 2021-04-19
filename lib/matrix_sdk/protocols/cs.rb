# frozen_string_literal: true

# rubocop:disable Metrics/ModuleLength
module MatrixSdk::Protocols::CS
  # Gets the available client API versions
  # @return [Array]
  #
  # @example Getting API versions
  #   api.client_api_versions
  #   # => [ 'r0.1.0', 'r0.2.0', ...
  #   api.client_api_versions.latest
  #   # => 'latest'
  def client_api_versions
    (@client_api_versions ||= request(:get, :client, '/versions')).versions.tap do |vers|
      vers.instance_eval <<-'CODE', __FILE__, __LINE__ + 1
        def latest
          last
        end
      CODE
    end
  end

  # Gets the list of available unstable client API features
  # @return [Hash]
  #
  # @example Checking for unstable features
  #   api.client_api_unstable_features
  #   # => { :"m.lazy_load_members" => true }
  #   api.client_api_unstable_features.has? 'm.lazy_load_members'
  #   # => true
  def client_api_unstable_features
    (@client_api_versions ||= request(:get, :client, '/versions')).unstable_features.tap do |vers|
      vers.instance_eval <<-'CODE', __FILE__, __LINE__ + 1
        def has?(feature)
          feature = feature.to_s.to_sym unless feature.is_a? Symbol
          fetch(feature, nil)
        end
      CODE
    end
  end

  # Gets the list of available methods for logging in
  # @return [Response]
  def allowed_login_methods
    request(:get, :client_r0, '/login')
  end

  # Runs the client API /sync method
  # @param timeout [Numeric] (30.0) The timeout in seconds for the sync
  # @param params [Hash] The sync options to use
  # @option params [String] :since The value of the batch token to base the sync from
  # @option params [String,Hash] :filter The filter to use on the sync
  # @option params [Boolean] :full_state Should the sync include the full state
  # @option params [Boolean] :set_presence Should the sync set the user status to online
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/latest.html#get-matrix-client-r0-sync
  #      For more information on the parameters and what they mean
  def sync(timeout: 30.0, **params)
    query = params.select do |k, _v|
      %i[since filter full_state set_presence].include? k
    end

    query[:timeout] = (timeout * 1000).to_i if timeout
    query[:timeout] = params.delete(:timeout_ms).to_i if params.key? :timeout_ms
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

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
  # @param kind [String,Symbol] ('user') The kind of registration to use
  # @param params [Hash] The registration information, all not handled by Ruby will be passed as JSON in the body
  # @option params [Boolean] :store_token (true) Should the resulting access token be stored for the API
  # @option params [Boolean] :store_device_id (store_token value) Should the resulting device ID be stored for the API
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/latest.html#post-matrix-client-r0-register
  #      For options that are permitted in this call
  def register(kind: 'user', **params)
    query = {}
    query[:kind] = kind
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    store_token = params.delete(:store_token) { !protocol?(:AS) }
    store_device_id = params.delete(:store_device_id) { store_token }

    request(:post, :client_r0, '/register', body: params, query: query).tap do |resp|
      @access_token = resp.token if resp.key?(:token) && store_token
      @device_id = resp.device_id if resp.key?(:device_id) && store_device_id
    end
  end

  # Requests to register an email address to the current account
  #
  # @param secret [String] A random string containing only the characters `[0-9a-zA-Z.=_-]`
  # @param email [String] The email address to register
  # @param attempt [Integer] The current attempt count to register the email+secret combo, increase to send another verification email
  # @param next_link [String,URI] An URL to redirect to after verification is finished
  # @return [Response] A hash containing the :sid id for the current request
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-register-email-requesttoken
  #      For options that are permitted in this call
  def register_email_request(secret, email, attempt: 1, next_link: nil)
    body = {
      client_secret: secret,
      email: email,
      send_attempt: attempt,
      next_link: next_link
    }.compact

    request(:post, :client_r0, '/register/email/requestToken', body: body)
  end

  # Requests to register a phone number to the current account
  #
  # @param secret [String] A random string containing only the characters `[0-9a-zA-Z.=_-]`
  # @param country [String] The two-letter ISO-3166-1 country identifier of the destination country of the number
  # @param number [String] The phone number itself
  # @param attempt [Integer] The current attempt count to register the email+secret combo, increase to send another verification email
  # @param next_link [String,URI] An URL to redirect to after verification is finished
  # @return [Response] A hash containing the :sid id for the current request
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-register-email-requesttoken
  #      For options that are permitted in this call
  def register_msisdn_request(secret, country, number, attempt: 1, next_link: nil)
    body = {
      client_secret: secret,
      country: country,
      phone_number: number,
      send_attempt: attempt,
      next_link: next_link
    }.compact

    request(:post, :client_r0, '/register/msisdn/requestToken', body: body)
  end

  # Checks if a given username is available and valid for registering
  #
  # @example Verifying a username
  #   api.username_available?('example')
  #   # => { available: true }
  #
  # @param username [String] The username to check
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/latest.html#get-matrix-client-r0-register-available
  def username_available?(username)
    request(:get, :client_r0, '/register/available', query: { username: username })
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
  # @param login_type [String] ('m.login.password') The type of login to attempt
  # @param params [Hash] The login information to use, along with options for said log in
  # @option params [Boolean] :store_token (true) Should the resulting access token be stored for the API
  # @option params [Boolean] :store_device_id (store_token value) Should the resulting device ID be stored for the API
  # @option params [String] :initial_device_display_name (USER_AGENT) The device display name to specify for this login attempt
  # @option params [String] :device_id The device ID to set on the login
  # @return [Response] A response hash with the parameters :user_id, :access_token, :home_server, and :device_id.
  # @see https://matrix.org/docs/spec/client_server/latest.html#post-matrix-client-r0-login
  #      The Matrix Spec, for more information about the call and response
  def login(login_type: 'm.login.password', **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    options = {}
    options[:store_token] = params.delete(:store_token) { true }
    options[:store_device_id] = params.delete(:store_device_id) { options[:store_token] }

    data = {
      type: login_type,
      initial_device_display_name: params.delete(:initial_device_display_name) { MatrixSdk::Api::USER_AGENT }
    }.merge params
    data[:device_id] = device_id if device_id

    request(:post, :client_r0, '/login', body: data, query: query).tap do |resp|
      @access_token = resp.token if resp.key?(:token) && options[:store_token]
      @device_id = resp.device_id if resp.key?(:device_id) && options[:store_device_id]
    end
  end

  # Logs out the currently logged in device for the current user
  # @return [Response] An empty response if the logout was successful
  # @see https://matrix.org/docs/spec/client_server/latest.html#post-matrix-client-r0-logout
  #      The Matrix Spec, for more information about the call and response
  def logout(**params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:post, :client_r0, '/logout', query: query)
  end

  # Logs out the currently logged in user
  # @return [Response] An empty response if the logout was successful
  # @see https://matrix.org/docs/spec/client_server/latest.html#post-matrix-client-r0-logout-all
  #      The Matrix Spec, for more information about the call and response
  def logout_all(**params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:post, :client_r0, '/logout/all', query: query)
  end

  # Changes the users password
  # @param new_password [String] The new password
  # @param auth [Hash] An auth object returned from an interactive auth query
  # @return [Response] An empty response if the password change was successful
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-account-password
  #      The Matrix Spec, for more information about the call and response
  def change_password(new_password, auth:, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    # raise Error unless auth.is_a?(Hash) && auth.key? :type

    body = {
      new_password: new_password,
      auth: auth
    }

    request(:post, :client_r0, '/account/password', body: body, query: query)
  end

  # Requests an authentication token based on an email address
  #
  # @param secret [String] A random string containing only the characters `[0-9a-zA-Z.=_-]`
  # @param email [String] The email address to register
  # @param attempt [Integer] The current attempt count to register the email+secret combo, increase to send another verification email
  # @param next_link [String,URI] An URL to redirect to after verification is finished
  # @return [Response] A hash containing the :sid id for the current request
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-account-password-email-requesttoken
  #      For options that are permitted in this call
  def request_email_login_token(secret, email, attempt: 1, next_link: nil)
    body = {
      client_secret: secret,
      email: email,
      send_attempt: attempt,
      next_link: next_link
    }.compact

    request(:post, :client_r0, '/account/password/email/requestToken', body: body)
  end

  # Requests an authentication token based on a phone number
  #
  # @param secret [String] A random string containing only the characters `[0-9a-zA-Z.=_-]`
  # @param country [String] The two-letter ISO-3166-1 country identifier of the destination country of the number
  # @param number [String] The phone number itself
  # @param attempt [Integer] The current attempt count to register the email+secret combo, increase to send another verification email
  # @param next_link [String,URI] An URL to redirect to after verification is finished
  # @return [Response] A hash containing the :sid id for the current request
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-account-password-msisdn-requesttoken
  #      For options that are permitted in this call
  def request_msisdn_login_token(secret, country, number, attempt: 1, next_link: nil)
    body = {
      client_secret: secret,
      country: country,
      phone_number: number,
      send_attempt: attempt,
      next_link: next_link
    }.compact

    request(:post, :client_r0, '/account/password/msisdn/requestToken', body: body)
  end

  # Deactivates the current account, logging out all connected devices and preventing future logins
  #
  # @param auth_data [Hash] Interactive authentication data to verify the request
  # @param id_server [String] Override the ID server to unbind all 3PIDs from
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-account-deactivate
  #      For options that are permitted in this call
  def deactivate_account(auth_data, id_server: nil)
    body = {
      auth: auth_data,
      id_server: id_server
    }.compact

    request(:post, :client_r0, '/account/deactivate', body: body)
  end

  def get_3pids(**params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:get, :client_r0, '/account/3pid', query: query)
  end

  # Finishes a 3PID addition to the current user
  #
  # @param secret [String] The shared secret with the HS
  # @param session [String] The session ID to finish the request for
  # @param auth_data [Hash] Interactive authentication data to verify the request
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-account-3pid-add
  #      For options that are permitted in this call
  def complete_3pid_add(secret:, session:, auth_data: nil)
    body = {
      sid: session,
      client_secret: secret,
      auth: auth_data
    }.compact

    request(:post, :client_r0, '/account/3pid/add', body: body)
  end

  # Finishes binding a 3PID to the current user
  #
  # @param secret [String] The shared secret with the identity server
  # @param id_server [String] The identity server being acted against
  # @param id_server_token [String] A previous identity server token
  # @param session [String] The session ID to finish the bind for
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-account-3pid-bind
  #      For options that are permitted in this call
  def bind_3pid(secret:, id_server:, id_server_token:, session:)
    body = {
      client_secret: secret,
      id_server: id_server,
      id_server_token: id_server_token,
      sid: session
    }

    request(:post, :client_r0, '/account/3pid/bind', body: body)
  end

  # Deletes a 3PID from the current user, this method might not unbind it from the identity server
  #
  # @param medium [:email,:msisdn] The medium of 3PID being removed
  # @param address [String] The address that is to be removed
  # @param id_server [String] The identity server being acted against
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-account-3pid-delete
  #      For options that are permitted in this call
  def delete_3pid(medium, address, id_server:)
    body = {
      address: address,
      id_server: id_server,
      medium: medium
    }

    request(:post, :client_r0, '/account/3pid/delete', body: body)
  end

  # Unbinds a 3PID from the current user
  #
  # @param medium [:email,:msisdn] The medium of 3PID being removed
  # @param address [String] The address that is to be removed
  # @param id_server [String] The identity server being acted against
  # @return [Response]
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-account-3pid-unbind
  #      For options that are permitted in this call
  def unbind_3pid(medium, address, id_server:)
    body = {
      address: address,
      id_server: id_server,
      medium: medium
    }

    request(:post, :client_r0, '/account/3pid/unbind', body: body)
  end

  # Gets the list of rooms joined by the current user
  #
  # @return [Response] An array of room IDs under the key :joined_rooms
  # @see https://matrix.org/docs/spec/client_server/latest.html#get-matrix-client-r0-joined-rooms
  def get_joined_rooms(**params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:get, :client_r0, '/joined_rooms', query: query)
  end

  # Gets the list of public rooms on a Matrix server
  #
  # @param limit [Integer] Limits the number of results returned
  # @param since [String] A pagination token received from an earlier call
  # @param server [String] The Matrix server to request public rooms from
  # @return [Response] An array of public rooms in the :chunk key, along with
  #                    :next_batch, :prev_batch, and :total_room_count_estimate
  #                    for pagination
  # @see https://matrix.org/docs/spec/client_server/latest.html#get-matrix-client-r0-publicrooms
  #      https://matrix.org/docs/spec/client_server/latest.html#post-matrix-client-r0-publicrooms
  def get_public_rooms(server: nil, **params)
    query = {
      server: server
    }.compact
    body = nil
    method = :get

    if !params[:filter].nil? || !params[:include_all_networks].nil? || !params[:third_party_instance_id].nil?
      body = {
        limit: params[:limit],
        since: params[:since],
        filter: params[:filter],
        include_all_networks: params[:include_all_networks],
        third_party_instance_id: params[:third_party_instance_id]
      }.merge(params).compact
      method = :post
    else
      query = query.merge(params).compact
    end

    request(method, :client_r0, '/publicRooms', query: query, body: body)
  end

  # Creates a new room
  # @param params [Hash] The room creation details
  # @option params [Symbol] :visibility (:public) The room visibility
  # @option params [String] :room_alias A room alias to apply on creation
  # @option params [Boolean] :invite Should the room be created invite-only
  # @return [Response] A response hash with ...
  # @see https://matrix.org/docs/spec/client_server/latest.html#post-matrix-client-r0-createroom
  #      The Matrix Spec, for more information about the call and response
  def create_room(visibility: :public, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      visibility: visibility
    }
    content[:room_alias_name] = params.delete(:room_alias) if params[:room_alias]
    content[:invite] = [params.delete(:invite)].flatten if params[:invite]
    content.merge! params

    request(:post, :client_r0, '/createRoom', body: content, query: query)
  end

  # Joins a room
  # @param id_or_alias [MXID,String] The room ID or Alias to join
  # @param params [Hash] Extra room join options
  # @option params [String[]] :server_name A list of servers to perform the join through
  # @return [Response] A response hash with the parameter :room_id
  # @see https://matrix.org/docs/spec/client_server/latest.html#post-matrix-client-r0-join-roomidoralias
  #      The Matrix Spec, for more information about the call and response
  # @todo Add support for 3rd-party signed objects
  def join_room(id_or_alias, **params)
    query = {}
    query[:server_name] = params[:server_name] if params[:server_name]
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    # id_or_alias = MXID.new id_or_alias.to_s unless id_or_alias.is_a? MXID
    # raise ArgumentError, 'Not a room ID or alias' unless id_or_alias.room?

    id_or_alias = ERB::Util.url_encode id_or_alias.to_s

    request(:post, :client_r0, "/join/#{id_or_alias}", query: query)
  end

  # Sends a state event to a room
  # @param room_id [MXID,String] The room ID to send the state event to
  # @param event_type [String] The event type to send
  # @param content [Hash] The contents of the state event
  # @param params [Hash] Options for the request
  # @option params [String] :state_key The state key of the event, if there is one
  # @return [Response] A response hash with the parameter :event_id
  # @see https://matrix.org/docs/spec/client_server/latest.html#put-matrix-client-r0-rooms-roomid-state-eventtype-statekey
  #      https://matrix.org/docs/spec/client_server/latest.html#put-matrix-client-r0-rooms-roomid-state-eventtype
  #      The Matrix Spec, for more information about the call and response
  def send_state_event(room_id, event_type, content, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s
    event_type = ERB::Util.url_encode event_type.to_s
    state_key = ERB::Util.url_encode params[:state_key].to_s if params.key? :state_key

    request(:put, :client_r0, "/rooms/#{room_id}/state/#{event_type}#{"/#{state_key}" unless state_key.nil?}", body: content, query: query)
  end

  # Sends a message event to a room
  # @param room_id [MXID,String] The room ID to send the message event to
  # @param event_type [String] The event type of the message
  # @param content [Hash] The contents of the message
  # @param params [Hash] Options for the request
  # @option params [Integer] :txn_id The ID of the transaction, or automatically generated
  # @return [Response] A response hash with the parameter :event_id
  # @see https://matrix.org/docs/spec/client_server/latest.html#put-matrix-client-r0-rooms-roomid-send-eventtype-txnid
  #      The Matrix Spec, for more information about the call and response
  def send_message_event(room_id, event_type, content, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    txn_id = transaction_id
    txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

    room_id = ERB::Util.url_encode room_id.to_s
    event_type = ERB::Util.url_encode event_type.to_s
    txn_id = ERB::Util.url_encode txn_id.to_s

    request(:put, :client_r0, "/rooms/#{room_id}/send/#{event_type}/#{txn_id}", body: content, query: query)
  end

  # Redact an event in a room
  # @param room_id [MXID,String] The room ID to send the message event to
  # @param event_id [String] The event ID of the event to redact
  # @param params [Hash] Options for the request
  # @option params [String] :reason The reason for the redaction
  # @option params [Integer] :txn_id The ID of the transaction, or automatically generated
  # @return [Response] A response hash with the parameter :event_id
  # @see https://matrix.org/docs/spec/client_server/latest.html#put-matrix-client-r0-rooms-roomid-redact-eventid-txnid
  #      The Matrix Spec, for more information about the call and response
  def redact_event(room_id, event_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {}
    content[:reason] = params[:reason] if params[:reason]

    txn_id = transaction_id
    txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

    room_id = ERB::Util.url_encode room_id.to_s
    event_id = ERB::Util.url_encode event_id.to_s
    txn_id = ERB::Util.url_encode txn_id.to_s

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
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-image
  #      https://matrix.org/docs/spec/client_server/latest.html#m-file
  #      https://matrix.org/docs/spec/client_server/latest.html#m-video
  #      https://matrix.org/docs/spec/client_server/latest.html#m-audio
  #      The Matrix Spec, for more information about the call and response
  def send_content(room_id, url, name, msg_type, **params)
    content = {
      url: url,
      msgtype: msg_type,
      body: name,
      info: params.delete(:extra_information) { {} }
    }
    content.merge!(params.fetch(:extra_content)) if params.key? :extra_content

    send_message_event(room_id, 'm.room.message', content, **params)
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
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-location
  #      The Matrix Spec, for more information about the call and response
  def send_location(room_id, geo_uri, name, **params)
    content = {
      geo_uri: geo_uri,
      msgtype: 'm.location',
      body: name,
      info: params.delete(:extra_information) { {} }
    }
    content[:info][:thumbnail_url] = params.delete(:thumbnail_url) if params.key? :thumbnail_url
    content[:info][:thumbnail_info] = params.delete(:thumbnail_info) if params.key? :thumbnail_info

    send_message_event(room_id, 'm.room.message', content, **params)
  end

  # Send a plaintext message to a room
  #
  # @param room_id [MXID,String] The room ID to send the message to
  # @param message [String] The message to send
  # @param params [Hash] Options for the request
  # @option params [String] :msg_type ('m.text') The message type to send
  # @return [Response] A response hash with the parameter :event_id
  # @see send_message_event For more information on the underlying call
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-text
  #      The Matrix Spec, for more information about the call and response
  def send_message(room_id, message, **params)
    content = {
      msgtype: params.delete(:msg_type) { 'm.text' },
      body: message
    }
    send_message_event(room_id, 'm.room.message', content, **params)
  end

  # Send a plaintext emote to a room
  #
  # @param room_id [MXID,String] The room ID to send the message to
  # @param emote [String] The emote to send
  # @param params [Hash] Options for the request
  # @option params [String] :msg_type ('m.emote') The message type to send
  # @return [Response] A response hash with the parameter :event_id
  # @see send_message_event For more information on the underlying call
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-emote
  #      The Matrix Spec, for more information about the call and response
  def send_emote(room_id, emote, **params)
    content = {
      msgtype: params.delete(:msg_type) { 'm.emote' },
      body: emote
    }
    send_message_event(room_id, 'm.room.message', content, **params)
  end

  # Send a plaintext notice to a room
  #
  # @param room_id [MXID,String] The room ID to send the message to
  # @param notice [String] The notice to send
  # @param params [Hash] Options for the request
  # @option params [String] :msg_type ('m.notice') The message type to send
  # @return [Response] A response hash with the parameter :event_id
  # @see send_message_event For more information on the underlying call
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-notice
  #      The Matrix Spec, for more information about the call and response
  def send_notice(room_id, notice, **params)
    content = {
      msgtype: params.delete(:msg_type) { 'm.notice' },
      body: notice
    }
    send_message_event(room_id, 'm.room.message', content, **params)
  end

  # Report an event in a room
  #
  # @param room_id [MXID,String] The room ID in which the event occurred
  # @param room_id [MXID,String] The event ID to report
  # @param score [Integer] The severity of the report, range between -100 - 0
  # @param reason [String] The reason for the report
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-rooms-roomid-report-eventid
  #      The Matrix Spec, for more information about the call and response
  def report_event(room_id, event_id, score:, reason:, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    body = {
      score: score,
      reason: reason
    }

    room_id = ERB::Util.url_encode room_id.to_s
    event_id = ERB::Util.url_encode event_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/report/#{event_id}", body: body, query: query)
  end

  # Retrieve additional messages in a room
  #
  # @param room_id [MXID,String] The room ID to retrieve messages for
  # @param token [String] The token to start retrieving from, can be from a sync or from an earlier get_room_messages call
  # @param direction [:b,:f] The direction to retrieve messages
  # @param limit [Integer] (10) The limit of messages to retrieve
  # @param params [Hash] Additional options for the request
  # @option params [String] :to A token to limit retrieval to
  # @option params [String] :filter A filter to limit the retrieval to
  # @return [Response] A response hash with the message information containing :start, :end, and :chunk fields
  # @see https://matrix.org/docs/spec/client_server/latest.html#get-matrix-client-r0-rooms-roomid-messages
  #      The Matrix Spec, for more information about the call and response
  def get_room_messages(room_id, token, direction:, limit: 10, **params)
    query = {
      from: token,
      dir: direction,
      limit: limit
    }
    query[:to] = params[:to] if params.key? :to
    query[:filter] = params.fetch(:filter) if params.key? :filter
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/messages", query: query)
  end

  # Gets a specific event from a room
  #
  # @param room_id [MXID,String] The room ID to read from
  # @param event_id [MXID,String] The event ID to retrieve
  # @return [Response] A response hash with the contents of the event
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-rooms-roomid-event-eventid
  #      The Matrix Spec, for more information about the call and response
  def get_room_event(room_id, event_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s
    event_id = ERB::Util.url_encode event_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/event/#{event_id}", query: query)
  end

  # Reads the latest instance of a room state event
  #
  # @param room_id [MXID,String] The room ID to read from
  # @param state_type [String] The state type to read
  # @return [Response] A response hash with the contents of the state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#get-matrix-client-r0-rooms-roomid-state-eventtype
  #      The Matrix Spec, for more information about the call and response
  def get_room_state(room_id, state_type, key: nil, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s
    state_type = ERB::Util.url_encode state_type.to_s
    key = ERB::Util.url_encode key.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/state/#{state_type}#{key.empty? ? nil : "/#{key}"}", query: query)
  end

  # Retrieves all current state objects from a room
  #
  # @param room_id [MXID,String] The room ID to read from
  # @return [Response] A response hash with the contents of all state events
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-rooms-roomid-event-eventid
  #      The Matrix Spec, for more information about the call and response
  def get_room_state_all(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/state", query: query)
  end

  # Retrieves number of events that happened just before and after the specified event
  #
  # @param room_id [MXID,String] The room to get events from.
  # @param event_id [MXID,String] The event to get context around.
  # @option params [Integer] :limit (10) The limit of messages to retrieve
  # @option params [String] :filter A filter to limit the retrieval to
  # @return [Response] A response hash with contextual event information
  # @see https://matrix.org/docs/spec/client_server/r0.6.1#get-matrix-client-r0-rooms-roomid-context-eventid
  #      The Matrix Spec, for more information about the call and response
  # @example Find event context with filter and limit specified
  #   api.get_room_event_context('#room:example.com', '$event_id:example.com', filter: { types: ['m.room.message'] }.to_json, limit: 20)
  def get_room_event_context(room_id, event_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    query[:limit] = params.fetch(:limit) if params.key? :limit
    query[:filter] = params.fetch(:filter) if params.key? :filter

    room_id = ERB::Util.url_encode room_id.to_s
    event_id = ERB::Util.url_encode event_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/context/#{event_id}", query: query)
  end

  ## Specialized getters for specced state
  #

  # Gets the current display name of a room
  #
  # @param room_id [MXID,String] The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the parameter :name
  # @raise [MatrixNotFoundError] Raised if no name has been set on the room
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-name
  #      The Matrix Spec, for more information about the event and data
  def get_room_name(room_id, **params)
    get_room_state(room_id, 'm.room.name', **params)
  end

  # Sets the display name of a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [String] name The new name of the room
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-name
  #      The Matrix Spec, for more information about the event and data
  def set_room_name(room_id, name, **params)
    content = {
      name: name
    }
    send_state_event(room_id, 'm.room.name', content, **params)
  end

  # Gets the current topic of a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the parameter :topic
  # @raise [MatrixNotFoundError] Raised if no topic has been set on the room
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-topic
  #      The Matrix Spec, for more information about the event and data
  def get_room_topic(room_id, **params)
    get_room_state(room_id, 'm.room.topic', **params)
  end

  # Sets the topic of a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [String] topic The new topic of the room
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-topic
  #      The Matrix Spec, for more information about the event and data
  def set_room_topic(room_id, topic, **params)
    content = {
      topic: topic
    }
    send_state_event(room_id, 'm.room.topic', content, **params)
  end

  # Gets the current avatar URL of a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the parameters :url and (optionally) :info
  # @raise [MatrixNotFoundError] Raised if no avatar has been set on the room
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-avatar
  #      The Matrix Spec, for more information about the event and data
  def get_room_avatar(room_id, **params)
    get_room_state(room_id, 'm.room.avatar', **params)
  end

  # Sets the avatar URL for a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [String,URI] url The new avatar URL for the room
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-avatar
  #      The Matrix Spec, for more information about the event and data
  def set_room_avatar(room_id, url, **params)
    content = {
      url: url
    }
    send_state_event(room_id, 'm.room.avatar', content, **params)
  end

  # Gets a list of current aliases of a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the array :aliases
  # @raise [MatrixNotFoundError] Raised if no aliases has been set on the room by the specified HS
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-avatar
  #      The Matrix Spec, for more information about the event and data
  # @example Looking up aliases for a room
  #   api.get_room_aliases('!QtykxKocfZaZOUrTwp:matrix.org')
  #   # MatrixSdk::MatrixNotFoundError: HTTP 404 (M_NOT_FOUND): Event not found.
  #   api.get_room_aliases('!QtykxKocfZaZOUrTwp:matrix.org', key: 'matrix.org')
  #   # => {:aliases=>["#matrix:matrix.org"]}
  #   api.get_room_aliases('!QtykxKocfZaZOUrTwp:matrix.org', key: 'kittenface.studio')
  #   # => {:aliases=>["#worlddominationhq:kittenface.studio"]}
  # @example A way to find all aliases for a room
  #   api.get_room_state('!mjbDjyNsRXndKLkHIe:matrix.org')
  #      .select { |ch| ch[:type] == 'm.room.aliases' }
  #      .map { |ch| ch[:content][:aliases] }
  #      .flatten
  #      .compact
  #   # => ["#synapse:im.kabi.tk", "#synapse:matrix.org", "#synapse-community:matrix.org", "#synapse-ops:matrix.org", "#synops:matrix.org", ...
  def get_room_aliases(room_id, **params)
    get_room_state(room_id, 'm.room.aliases', **params)
  end

  # Gets a list of pinned events in a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the array :pinned
  # @raise [MatrixNotFoundError] Raised if no aliases has been set on the room by the specified HS
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-pinned-events
  #      The Matrix Spec, for more information about the event and data
  def get_room_pinned_events(room_id, **params)
    get_room_state(room_id, 'm.room.pinned_events', **params)
  end

  # Sets the list of pinned events in a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [Array[String]] events The new list of events to set as pinned
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-pinned-events
  #      The Matrix Spec, for more information about the event and data
  def set_room_pinned_events(room_id, events, **params)
    content = {
      pinned: events
    }
    send_state_event(room_id, 'm.room.pinned_events', content, **params)
  end

  # Gets the configured power levels for a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with power level information
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-power-levels
  #      The Matrix Spec, for more information about the event and data
  def get_room_power_levels(room_id, **params)
    get_room_state(room_id, 'm.room.power_levels', **params)
  end
  alias get_power_levels get_room_power_levels

  # Sets the configuration for power levels in a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [Hash] content The new power level configuration
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-power-levels
  #      The Matrix Spec, for more information about the event and data
  def set_room_power_levels(room_id, content, **params)
    content[:events] = {} unless content.key? :events
    send_state_event(room_id, 'm.room.power_levels', content, **params)
  end
  alias set_power_levels set_room_power_levels

  # Gets the join rules for a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the key :join_rule
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-join-rules
  #      The Matrix Spec, for more information about the event and data
  def get_room_join_rules(room_id, **params)
    get_room_state(room_id, 'm.room.join_rules', **params)
  end

  # Sets the join rules for a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [String,Symbol] join_rule The new join rule setting (Currently only public and invite are implemented)
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-join-rules
  #      The Matrix Spec, for more information about the event and data
  def set_room_join_rules(room_id, join_rule, **params)
    content = {
      join_rule: join_rule
    }

    send_state_event(room_id, 'm.room.join_rules', content, **params)
  end

  # Gets the guest access settings for a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the key :guest_acces, either :can_join or :forbidden
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-guest-access
  #      The Matrix Spec, for more information about the event and data
  def get_room_guest_access(room_id, **params)
    get_room_state(room_id, 'm.room.guest_access', **params)
  end

  # Sets the guest access settings for a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [:can_join, :forbidden] guest_access The new guest access setting for the room
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-guest-access
  #      The Matrix Spec, for more information about the event and data
  def set_room_guest_access(room_id, guest_access, **params)
    content = {
      guest_access: guest_access
    }

    send_state_event(room_id, 'm.room.guest_access', content, **params)
  end

  # Gets the creation configuration object for a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the configuration the room was created for
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-create
  #      The Matrix Spec, for more information about the event and data
  def get_room_creation_info(room_id, **params)
    get_room_state(room_id, 'm.room.create', **params)
  end

  # Gets the encryption configuration for a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the configuration the room was created for
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-encryption
  #      The Matrix Spec, for more information about the event and data
  def get_room_encryption_settings(room_id, **params)
    get_room_state(room_id, 'm.room.encryption', **params)
  end

  # Sets the encryption configuration for a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param ['m.megolm.v1.aes-sha2'] algorithm The encryption algorithm to use
  # @param [Integer] rotation_period_ms The interval between key rotation in milliseconds
  # @param [Integer] rotation_period_msgs The interval between key rotation in messages
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-guest-encryption
  #      The Matrix Spec, for more information about the event and data
  def set_room_encryption_settings(room_id, algorithm: 'm.megolm.v1.aes-sha2', rotation_period_ms: 1 * 7 * 24 * 60 * 60 * 1000, rotation_period_msgs: 100, **params)
    content = {
      algorithm: algorithm,
      rotation_period_ms: rotation_period_ms,
      rotation_period_msgs: rotation_period_msgs
    }
    send_state_event(room_id, 'm.room.encryption', content, **params)
  end

  # Gets the history availabiilty for a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with the key :history_visibility
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-history-visibility
  #      The Matrix Spec, for more information about the event and data
  def get_room_history_visibility(room_id, **params)
    get_room_state(room_id, 'm.room.history_visibility', **params)
  end

  # Sets the history availability for a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [:invited, :joined, :shared, :world_readable] visibility The new history visibility level
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-guest-history-visibility
  #      The Matrix Spec, for more information about the event and data
  def set_room_history_visibility(room_id, visibility, **params)
    content = {
      history_visibility: visibility
    }

    send_state_event(room_id, 'm.room.history_visibility', content, **params)
  end

  # Gets the server ACLs for a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @param [Hash] params Extra options to provide to the request, see #get_room_state
  # @return [Response] A response hash with server ACL information
  # @see get_room_state
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-server-acl
  #      The Matrix Spec, for more information about the event and data
  def get_room_server_acl(room_id, **params)
    get_room_state(room_id, 'm.room.server_acl', **params)
  end

  # Sets the server ACL configuration for a room
  #
  # @param [MXID,String] room_id The room ID to work on
  # @param [Boolean] allow_ip_literals If HSes with literal IP domains should be allowed
  # @param [Array[String]] allow A list of HS wildcards that are allowed to communicate with the room
  # @param [Array[String]] deny A list of HS wildcards that are denied from communicating with the room
  # @param [Hash] params Extra options to set on the request, see #send_state_event
  # @return [Response] The resulting state event
  # @see https://matrix.org/docs/spec/client_server/latest.html#m-room-guest-server-acl
  #      The Matrix Spec, for more information about the event and data
  def set_room_server_acl(room_id, allow:, deny:, allow_ip_literals: false, **params)
    content = {
      allow_ip_literals: allow_ip_literals,
      allow: allow,
      deny: deny
    }

    send_state_event(room_id, 'm.room.server_acl', content, **params)
  end

  def leave_room(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/leave", query: query)
  end

  def forget_room(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/forget", query: query)
  end

  # Directly joins a room by ID
  #
  # @param room_id [MXID,String] The room ID to join
  # @param third_party_signed [Hash] The 3PID signature allowing the user to join
  # @return [Response] A response hash with the parameter :room_id
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-rooms-roomid-join
  #      The Matrix Spec, for more information about the call and response
  def join_room_id(room_id, third_party_signed: nil, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    body = {
      third_party_signed: third_party_signed
    }.compact

    room_id = ERB::Util.url_encode room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/join", body: body, query: query)
  end

  def invite_user(room_id, user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      user_id: user_id
    }

    room_id = ERB::Util.url_encode room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/invite", body: content, query: query)
  end

  def kick_user(room_id, user_id, reason: '', **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      user_id: user_id,
      reason: reason
    }
    room_id = ERB::Util.url_encode room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/kick", body: content, query: query)
  end

  def get_membership(room_id, user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s
    user_id = ERB::Util.url_encode user_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/state/m.room.member/#{user_id}", query: query)
  end

  def set_membership(room_id, user_id, membership, reason: '', **params)
    content = {
      membership: membership,
      reason: reason
    }
    content[:displayname] = params.delete(:displayname) if params.key? :displayname
    content[:avatar_url] = params.delete(:avatar_url) if params.key? :avatar_url

    send_state_event(room_id, 'm.room.member', content, params.merge(state_key: user_id))
  end

  def ban_user(room_id, user_id, reason: '', **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      user_id: user_id,
      reason: reason
    }
    room_id = ERB::Util.url_encode room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/ban", body: content, query: query)
  end

  def unban_user(room_id, user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      user_id: user_id
    }
    room_id = ERB::Util.url_encode room_id.to_s

    request(:post, :client_r0, "/rooms/#{room_id}/unban", body: content, query: query)
  end

  # Gets the room directory visibility status for a room
  #
  # @param [MXID,String] room_id The room ID to look up
  # @return [Response] A response hash with a :visibility key
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-directory-list-room-roomid
  #      The Matrix Spec, for more information about the event and data
  def get_room_directory_visibility(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s

    request(:get, :client_r0, "/directory/list/room/#{room_id}", query: query)
  end

  # Sets the room directory visibility status for a room
  #
  # @param [MXID,String] room_id The room ID to change visibility for
  # @param [:public,:private] visibility The new visibility status
  # @return [Response] An empty response hash if the visibilty change succeeded
  # @see https://matrix.org/docs/spec/client_server/latest#put-matrix-client-r0-directory-list-room-roomid
  #      The Matrix Spec, for more information about the event and data
  def set_room_directory_visibility(room_id, visibility, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    body = {
      visibility: visibility
    }

    room_id = ERB::Util.url_encode room_id.to_s

    request(:put, :client_r0, "/directory/list/room/#{room_id}", body: body, query: query)
  end

  def get_user_tags(user_id, room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s
    user_id = ERB::Util.url_encode user_id.to_s

    request(:get, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags", query: query)
  end

  def remove_user_tag(user_id, room_id, tag, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s
    user_id = ERB::Util.url_encode user_id.to_s
    tag = ERB::Util.url_encode tag.to_s

    request(:delete, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags/#{tag}", query: query)
  end

  def add_user_tag(user_id, room_id, tag, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    if params[:body]
      content = params[:body]
    else
      content = {}
      content[:order] = params[:order] if params.key? :order
    end

    room_id = ERB::Util.url_encode room_id.to_s
    user_id = ERB::Util.url_encode user_id.to_s
    tag = ERB::Util.url_encode tag.to_s

    request(:put, :client_r0, "/user/#{user_id}/rooms/#{room_id}/tags/#{tag}", body: content, query: query)
  end

  def get_account_data(user_id, type_key, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s
    type_key = ERB::Util.url_encode type_key.to_s

    request(:get, :client_r0, "/user/#{user_id}/account_data/#{type_key}", query: query)
  end

  def set_account_data(user_id, type_key, account_data, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s
    type_key = ERB::Util.url_encode type_key.to_s

    request(:put, :client_r0, "/user/#{user_id}/account_data/#{type_key}", body: account_data, query: query)
  end

  def get_room_account_data(user_id, room_id, type_key, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s
    room_id = ERB::Util.url_encode room_id.to_s
    type_key = ERB::Util.url_encode type_key.to_s

    request(:get, :client_r0, "/user/#{user_id}/rooms/#{room_id}/account_data/#{type_key}", query: query)
  end

  def set_room_account_data(user_id, room_id, type_key, account_data, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s
    room_id = ERB::Util.url_encode room_id.to_s
    type_key = ERB::Util.url_encode type_key.to_s

    request(:put, :client_r0, "/user/#{user_id}/rooms/#{room_id}/account_data/#{type_key}", body: account_data, query: query)
  end

  # Retrieve user information
  #
  # @param [String] user_id The MXID to look up
  # @return [Response] A response hash containing the requested user's information
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-admin-whois-userid
  #      The Matrix Spec, for more information about the parameters and data
  def whois(user_id)
    user_id = ERB::Util.url_encode user_id.to_s

    request(:get, :client_r0, "/admin/whois/#{user_id}")
  end

  def get_filter(user_id, filter_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s
    filter_id = ERB::Util.url_encode filter_id.to_s

    request(:get, :client_r0, "/user/#{user_id}/filter/#{filter_id}", query: query)
  end

  # Creates a filter for future use
  #
  # @param [String,MXID] user_id The user to create the filter for
  # @param [Hash] filter_params The filter to create
  def create_filter(user_id, filter_params, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s

    request(:post, :client_r0, "/user/#{user_id}/filter", body: filter_params, query: query)
  end

  def media_upload(content, content_type, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:post, :media_r0, '/upload', body: content, headers: { 'content-type' => content_type }, query: query)
  end

  def get_display_name(user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s

    request(:get, :client_r0, "/profile/#{user_id}/displayname", query: query)
  end

  def set_display_name(user_id, display_name, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      displayname: display_name
    }

    user_id = ERB::Util.url_encode user_id.to_s

    request(:put, :client_r0, "/profile/#{user_id}/displayname", body: content, query: query)
  end

  def get_avatar_url(user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s

    request(:get, :client_r0, "/profile/#{user_id}/avatar_url", query: query)
  end

  # Sets the avatar URL for a user
  #
  # @example Reuploading a gravatar as an avatar
  #   require 'digest/md5'
  #
  #   # Get a 256x256 gravatar of user@example.com, returning 404 if one doesn't exist
  #   email = 'user@example.com'
  #   url = "https://www.gravatar.com/avatar/#{Digest::MD5.hexdigest email.striprim.downcase}?d=404&s=256"
  #
  #   data = Net::HTTP.get_response(URI(url))
  #   data.value
  #
  #   # Reupload the gravatar to your connected HS before setting the resulting MXC URL as the new avatar
  #   mxc = api.media_upload(data.body, data.content_type)[:content_uri]
  #   api.set_avatar_url(api.whoami?[:user_id], mxc)
  #
  # @param [String,MXID] user_id The ID of the user to set the avatar for
  # @param [String,URI::MXC] url The new avatar URL, should be a mxc:// URL
  # @return [Response] An empty response hash if the change was successful
  # @see https://matrix.org/docs/spec/client_server/latest#put-matrix-client-r0-profile-userid-avatar-url
  #      The Matrix Spec, for more information about the event and data
  def set_avatar_url(user_id, url, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      avatar_url: url
    }

    user_id = ERB::Util.url_encode user_id.to_s

    request(:put, :client_r0, "/profile/#{user_id}/avatar_url", body: content, query: query)
  end

  # Gets the combined profile object of a user.
  #
  # This includes their display name and avatar
  #
  # @param [String,MXID] user_id The User ID to read the profile for
  # @return [Response] The user profile object
  # @see #get_display_name
  # @see #get_avatar_url
  def get_profile(user_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    user_id = ERB::Util.url_encode user_id.to_s

    request(:get, :client_r0, "/profile/#{user_id}", query: query)
  end

  # Gets TURN server connection information and credentials
  #
  # @return [Response] A response hash according to the spec
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-voip-turnserver
  #      The Matrix Spec, for more information about the event and data
  def get_turn_server
    request(:get, :client_r0, '/voip/turnServer')
  end

  # Sets the typing status for a user
  #
  # @param [String,MXID] room_id The ID of the room to set the typing status in
  # @param [String,MXID] user_id The ID of the user to set the typing status for
  # @param [Boolean] typing Is the user typing or not
  # @param [Numeric] timeout The timeout in seconds for how long the typing status should be valid
  # @return [Response] An empty response hash if the typing change was successful
  # @see https://matrix.org/docs/spec/client_server/latest#put-matrix-client-r0-rooms-roomid-typing-userid
  #      The Matrix Spec, for more information about the event and data
  def set_typing(room_id, user_id, typing: true, timeout: nil)
    room_id = ERB::Util.url_encode room_id.to_s
    user_id = ERB::Util.url_encode user_id.to_s

    body = {
      typing: typing,
      timeout: timeout ? timeout * 1000 : nil
    }.compact

    request(:put, :client_r0, "/rooms/#{room_id}/typing/#{user_id}", body: body)
  end

  # Gets the presence status of a user
  #
  # @param [String,MXID] user_id The User ID to read the status for
  # @return [Response] A response hash containing the current user presence status
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-presence-userid-status
  #      The Matrix Spec, for more information about the event and data
  def get_presence_status(user_id)
    user_id = ERB::Util.url_encode user_id.to_s

    request(:get, :client_r0, "/presence/#{user_id}/status")
  end

  # Sets the presence status of a user
  #
  # @param [String,MXID] user_id The User ID to set the status for
  # @param [:online,:offline,:unavailable] status The status to set
  # @param [String] messge The status message to store for the new status
  # @return [Response] An empty response hash if the status update succeeded
  # @note The specified user_id should be of the local user unless used for AS purposes
  # @see https://matrix.org/docs/spec/client_server/latest#put-matrix-client-r0-presence-userid-status
  #      The Matrix Spec, for more information about the event and data
  def set_presence_status(user_id, status, message: nil)
    user_id = ERB::Util.url_encode user_id.to_s

    body = {
      presence: status,
      status_msg: message
    }.compact

    request(:put, :client_r0, "/presence/#{user_id}/status", body: body)
  end

  # Converts a Matrix content URL (mxc://) to a media download URL
  # @param [String,URI] mxcurl The Matrix content URL to convert
  # @param [String,URI] source A source HS to use for the convertion, defaults to the connected HS
  # @return [URI] The full download URL for the requested piece of media
  #
  # @example Converting a MXC URL
  #   url = 'mxc://example.com/media_hash'
  #
  #   api.get_download_url(url)
  #   # => #<URI::HTTPS https://example.com/_matrix/media/r0/download/example.com/media_hash>
  #   api.get_download_url(url, source: 'matrix.org')
  #   # => #<URI::HTTPS https://matrix.org/_matrix/media/r0/download/example.com/media_hash>
  def get_download_url(mxcurl, source: nil, **_params)
    mxcurl = URI.parse(mxcurl.to_s) unless mxcurl.is_a? URI
    raise 'Not a mxc:// URL' unless mxcurl.is_a? URI::MXC

    if source
      source = "https://#{source}" unless source.include? '://'
      source = URI(source.to_s) unless source.is_a?(URI)
    end

    source ||= homeserver.dup
    source.tap do |u|
      full_path = mxcurl.full_path.to_s
      u.path = "/_matrix/media/r0/download/#{full_path}"
    end
  end

  # Gets a preview of the given URL
  #
  # @param [String,URI] url The URL to retrieve a preview for
  # @return [Response] A response hash containing OpenGraph data for the URL
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-media-r0-preview-url
  #      The Matrix Spec, for more information about the data
  def get_url_preview(url, timestamp: nil)
    ts = (timestamp.to_i * 1000) if timestamp.is_a? Time
    ts = timestamp if timestamp.is_a? Integer

    query = {
      url: url,
      ts: ts
    }.compact

    request(:get, :media_r0, '/preview_url', query: query)
  end

  # Gets the media configuration of the current server
  #
  # @return [Response] A response hash containing media configuration informtion
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-media-r0-config
  #      The Matrix Spec, for more information about the data
  def get_media_config
    request(:get, :media_r0, '/config')
  end

  # Sends events directly to the specified devices
  #
  # @param [String] event_type The type of event to send
  # @param [Hash] messages The hash of events to send and devices to send them to
  # @param [Hash] params Additional parameters
  # @option params [Integer] :txn_id The ID of the transaction, automatically generated if not specified
  # @see https://matrix.org/docs/spec/client_server/latest#put-matrix-client-r0-sendtodevice-eventtype-txnid
  #      The Matrix Spec, for more information about the data
  def send_to_device(event_type, messages:, **params)
    txn_id = transaction_id
    txn_id = params.fetch(:txn_id, "#{txn_id}#{Time.now.to_i}")

    event_type = ERB::Util.url_encode event_type.to_s
    txn_id = ERB::Util.url_encode txn_id.to_s

    body = {
      messages: messages
    }.compact

    request(:put, :client_r0, "/sendToDevice/#{event_type}/#{txn_id}", body: body)
  end

  # Gets the room ID for an alias
  # @param [String,MXID] room_alias The room alias to look up
  # @return [Response] An object containing the :room_id key and a key of :servers that know of the room
  # @raise [MatrixNotFoundError] No room with the requested alias exists
  def get_room_id(room_alias, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_alias = ERB::Util.url_encode room_alias.to_s

    request(:get, :client_r0, "/directory/room/#{room_alias}", query: query)
  end

  # Sets the room ID for an alias
  # @param [String,MXID] room_id The room to set an alias for
  # @param [String,MXID] room_alias The alias to configure for the room
  # @return [Response] An empty object denoting success
  # @raise [MatrixConflictError] The alias is already in use
  def set_room_alias(room_id, room_alias, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {
      room_id: room_id
    }
    room_alias = ERB::Util.url_encode room_alias.to_s

    request(:put, :client_r0, "/directory/room/#{room_alias}", body: content, query: query)
  end

  # Remove an alias from its room
  # @param [String,MXID] room_alias The alias to remove
  # @return [Response] An empty object denoting success
  def remove_room_alias(room_alias, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_alias = ERB::Util.url_encode room_alias.to_s

    request(:delete, :client_r0, "/directory/room/#{room_alias}", query: query)
  end

  # Gets a list of all the members in a room
  # @param [String,MXID] room_id The ID of the room
  # @return [Response] A chunked object
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-rooms-roomid-members
  #      The Matrix Spec, for more information about the data
  def get_room_members(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/members", query: query.merge(params))
  end

  # Gets a list of the joined members in a room
  #
  # @param [String,MXID] room_id The ID of the room
  # @return [Response] A chunked object
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-rooms-roomid-joined-members
  #      The Matrix Spec, for more information about the data
  def get_room_joined_members(room_id, **params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    room_id = ERB::Util.url_encode room_id.to_s

    request(:get, :client_r0, "/rooms/#{room_id}/joined_members", query: query)
  end

  # Gets a list of the current users registered devices
  # @return [Response] An object including all information about the users devices.
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-devices
  #      The Matrix Spec, for more information about the data
  def get_devices
    request(:get, :client_r0, '/devices')
  end

  # Gets the information about a certain client device
  # @param [String] device_id The ID of the device to look up
  # @return [Response] An object containing all available device information
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-devices-deviceid
  #      The Matrix Spec, for more information about the data
  def get_device(device_id)
    device_id = ERB::Util.url_encode device_id.to_s

    request(:get, :client_r0, "/devices/#{device_id}")
  end

  # Sets the metadata for a device
  # @param [String] device_id The ID of the device to modify
  # @param [String] display_name The new display name to set for the device
  # @see https://matrix.org/docs/spec/client_server/latest#put-matrix-client-r0-devices-deviceid
  #      The Matrix Spec, for more information about the data
  def set_device(device_id, display_name:)
    device_id = ERB::Util.url_encode device_id.to_s

    request(:put, :client_r0, "/devices/#{device_id}", body: { display_name: display_name })
  end

  # Removes a device from the current user
  # @param [String] device_id The device to remove
  # @param [Hash] auth Authentication data for the removal request
  # @raise [MatrixNotAuthorizeedError] The request did not contain enough authentication information,
  #        the data in this error will include the necessary information to perform interactive auth
  # @see https://matrix.org/docs/spec/client_server/latest#delete-matrix-client-r0-devices-deviceid
  #      The Matrix Spec, for more information about the data
  def delete_device(device_id, auth:)
    device_id = ERB::Util.url_encode device_id.to_s

    request(:delete, :client_r0, "/devices/#{device_id}", body: { auth: auth })
  end

  # Run a query for device keys
  # @param [Numeric] timeout The timeout - in seconds - for the query
  # @param [Array] device_keys The list of devices to query
  # @param [String] token The sync token that led to this query - if any
  # @param [Hash] params Additional parameters
  # @option params [Integer] timeout_ms The timeout in milliseconds for the query, overrides _timeout_
  # @example Looking up all the device keys for a user
  #   api.keys_query(device_keys: { '@alice:example.com': [] })
  #   # => { :device_keys => { :'@alice:example.com' => { :JLAFKJWSCS => { ...
  # @example Looking up a specific device for a user
  #   api.keys_query(device_keys: { '@alice:example.com': ['ABCDEFGHIJ'] })
  #   # => { :device_keys => { :'@alice:example.com' => { :ABCDEFGHIJ => { ...
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-keys-query
  #      The Matrix Spec, for more information about the parameters and data
  def keys_query(device_keys:, timeout: nil, token: nil, **params)
    body = {
      timeout: (timeout || 10) * 1000,
      device_keys: device_keys
    }
    body[:timeout] = params[:timeout_ms] if params.key? :timeout_ms
    body[:token] = token if token

    request(:post, :client_r0, '/keys/query', body: body)
  end

  # Claim one-time keys for pre-key messaging
  #
  # @param [Hash] one_time_keys Hash mapping user IDs to hashes of device IDs and key types
  # @param [Numeric] timeout (10) The timeout - in seconds - for the request
  # @return [Response] A response hash containing one-time keys for the requested users and devices
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-keys-claim
  #      The Matrix Spec, for more information about the parameters and data
  def claim_one_time_keys(one_time_keys, timeout: 10)
    body = {
      one_time_keys: one_time_keys,
      timeout: timeout * 1000
    }
    request(:post, :client_r0, '/keys/claim', body: body)
  end

  # Retrieve device key changes between two sync requests
  #
  # @param [String] from The sync token denoting the start of the range
  # @param [String] to The sync token denoting the end of the range
  # @return [Response] The users with device key changes during the specified range
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-keys-changes
  #      The Matrix Spec, for more information about the parameters and data
  def get_key_changes(from:, to:)
    query = {
      from: from,
      to: to
    }

    request(:get, :client_r0, '/keys/changes', query: query)
  end

  # Gets the list of registered pushers for the current user
  #
  # @return [Response] A response hash containing all the currently registered pushers for the current user
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-pushers
  #      The Matrix Spec, for more information about the parameters and data
  def get_pushers
    request(:get, :client_r0, '/pushers')
  end

  # rubocop:disable Metrics/ParameterLists

  # Sets a pusher on the current user
  #
  # @param [String] key The pushkey for the pusher, used for routing purposes and for unique identification in coordination with app_id
  # @param [String] kind The kind of pusher, should be either 'http' or 'email'
  # @param [String] app_id The ID of the application to push to
  # @param [String] app_name The user-visible name of the application to push to
  # @param [String] device_name The user-visible name of the device to push to
  # @param [String] lang The language that pushes should be sent in
  # @param [Hash] data Pusher configuration data, depends on the kind parameter
  # @param [Hash] params Additional optional parameters
  # @option params [String] profile_tag Specifies which device rules to use
  # @option params [Boolean] append Specifies if the pusher should replace or be appended to the pusher list based on uniqueness
  # @return [Response] An empty response hash if the pusher was added/replaced correctly
  # @see https://matrix.org/docs/spec/client_server/latest#post-matrix-client-r0-pushers
  #      The Matrix Spec, for more information about the parameters and data
  def set_pusher(key, kind:, app_id:, app_name:, device_name:, lang:, data:, **params)
    body = {
      pushkey: key,
      kind: kind,
      app_id: app_id,
      app_display_name: app_name,
      device_display_name: device_name,
      profile_tag: params[:profile_tag],
      lang: lang,
      data: data,
      append: params[:append]
    }.compact

    request(:post, :client_r0, '/pushers/set', body: body)
  end
  # rubocop:enable Metrics/ParameterLists

  # Enumerates the list of notifies that the current user has/should have received.
  #
  # @param [String] from The pagination token to continue reading events from
  # @param [Integer] limit The maximum number of event to return
  # @param [String] only A filter string that is to be applied to the notification events
  # @return [Response] A response hash containing notifications for the current user
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-notifications
  #      The Matrix Spec, for more information about the parameters and data
  def get_notifications(from: nil, limit: nil, only: nil)
    raise ArgumentError, 'Limit must be an integer' unless limit.nil? || limit.is_a?(Integer)

    query = {
      from: from,
      limit: limit,
      only: only
    }.compact

    request(:get, :client_r0, '/notifications', query: query)
  end

  # Retrieves the full list of registered push rules for the current user
  #
  # @return [Response] A response hash containing the current list of push rules for the current user
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-pushrules
  #      The Matrix Spec, for more information about the parameters and data
  def get_pushrules
    request(:get, :client_r0, '/pushrules/')
  end

  # Retrieves a single registered push rule for the current user
  #
  # @param [String] scope ('global') The scope to look up push rules from
  # @param [:override,:underride,:sender,:room,:content] kind The kind of push rule to look up
  # @param [String] id The ID of the rule that's being retrieved
  # @return [Response] A response hash containing the full data of the requested push rule
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-pushrules-scope-kind-ruleid
  #      The Matrix Spec, for more information about the parameters and data
  def get_pushrule(kind:, id:, scope: 'global')
    scope = ERB::Util.url_encode scope.to_s
    kind = ERB::Util.url_encode kind.to_s
    id = ERB::Util.url_encode id.to_s

    request(:get, :client_r0, "/pushrules/#{scope}/#{kind}/#{id}")
  end

  # Checks if a push rule for the current user is enabled
  #
  # @param [String] scope ('global') The scope to look up push rules from
  # @param [:override,:underride,:sender,:room,:content] kind The kind of push rule to look up
  # @param [String] id The ID of the rule that's being retrieved
  # @return [Response] A response hash containing an :enabled key for if the rule is enabled or not
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-pushrules-scope-kind-ruleid-enabled
  #      The Matrix Spec, for more information about the parameters and data
  def get_pushrule_enabled(kind:, id:, scope: 'global')
    scope = ERB::Util.url_encode scope.to_s
    kind = ERB::Util.url_encode kind.to_s
    id = ERB::Util.url_encode id.to_s

    request(:get, :client_r0, "/pushrules/#{scope}/#{kind}/#{id}/enabled")
  end

  # Enabled/Disables a specific push rule for the current user
  #
  # @param [Boolean] enabled Should the push rule be enabled or not
  # @param [String] scope ('global') The scope to look up push rules from
  # @param [:override,:underride,:sender,:room,:content] kind The kind of push rule to look up
  # @param [String] id The ID of the rule that's being retrieved
  # @return [Response] An empty response hash if the push rule was enabled/disabled successfully
  # @see https://matrix.org/docs/spec/client_server/latest#put-matrix-client-r0-pushrules-scope-kind-ruleid-enabled
  #      The Matrix Spec, for more information about the parameters and data
  def set_pushrule_enabled(enabled, kind:, id:, scope: 'global')
    scope = ERB::Util.url_encode scope.to_s
    kind = ERB::Util.url_encode kind.to_s
    id = ERB::Util.url_encode id.to_s

    body = {
      enabled: enabled
    }

    request(:put, :client_r0, "/pushrules/#{scope}/#{kind}/#{id}/enabled", body: body)
  end

  # Gets the current list of actions for a specific push rule for the current user
  #
  # @param [String] scope ('global') The scope to look up push rules from
  # @param [:override,:underride,:sender,:room,:content] kind The kind of push rule to look up
  # @param [String] id The ID of the rule that's being retrieved
  # @return [Response] A response hash containing an :enabled key for if the rule is enabled or not
  # @see https://matrix.org/docs/spec/client_server/latest#get-matrix-client-r0-pushrules-scope-kind-ruleid-actions
  #      The Matrix Spec, for more information about the parameters and data
  def get_pushrule_actions(kind:, id:, scope: 'global')
    scope = ERB::Util.url_encode scope.to_s
    kind = ERB::Util.url_encode kind.to_s
    id = ERB::Util.url_encode id.to_s

    request(:get, :client_r0, "/pushrules/#{scope}/#{kind}/#{id}/actions")
  end

  # Replaces the list of actions for a push rule for the current user
  #
  # @param [String,Array[String]] actions The list of actions to apply on the push rule
  # @param [String] scope ('global') The scope to look up push rules from
  # @param [:override,:underride,:sender,:room,:content] kind The kind of push rule to look up
  # @param [String] id The ID of the rule that's being retrieved
  # @return [Response] An empty response hash if the push rule actions were modified successfully
  # @see https://matrix.org/docs/spec/client_server/latest#put-matrix-client-r0-pushrules-scope-kind-ruleid-actions
  #      The Matrix Spec, for more information about the parameters and data
  def set_pushrule_actions(actions, kind:, id:, scope: 'global')
    scope = ERB::Util.url_encode scope.to_s
    kind = ERB::Util.url_encode kind.to_s
    id = ERB::Util.url_encode id.to_s

    actions = [actions] unless actions.is_a? Array

    body = {
      actions: actions
    }

    request(:put, :client_r0, "/pushrules/#{scope}/#{kind}/#{id}/actions", body: body)
  end

  # Gets the MXID of the currently logged-in user
  # @return [Response] An object containing the key :user_id
  def whoami?(**params)
    query = {}
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    request(:get, :client_r0, '/account/whoami', query: query)
  end
end
# rubocop:enable Metrics/ModuleLength
