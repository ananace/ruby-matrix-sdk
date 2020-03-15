# frozen_string_literal: true

# Preliminary support for unmerged MSCs (Matrix Spec Changes)
module MatrixSdk::Protocols::MSC
  def refresh_mscs
    @msc = {}
  end

  # Check if there's support for MSC2108 - Sync over Server Sent Events
  def msc2108?
    @msc ||= {}
    @msc[2108] ||= \
      begin
        request(:get, :client_r0, '/sync/sse', skip_auth: true, headers: { accept: 'text/event-stream' })
      rescue MatrixSdk::MatrixNotAuthorizedError # Returns 401 if implemented
        true
      rescue MatrixSdk::MatrixRequestError
        false
      end
  rescue StandardError => e
    logger.debug "Failed to check MSC2108 status;\n#{e.inspect}"
    false
  end

  # Sync over Server Sent Events - MSC2108
  #
  # @note With the default Ruby Net::HTTP server, body fragments are cached up to 16kB,
  #       which will result in large batches and delays if your filters trim a lot of data.
  #
  # @example Syncing over SSE
  #   @since = 'some token'
  #   api.msc2108_sync_sse(since: @since) do |data, event:, id:|
  #     if event == 'sync'
  #       handle(data) # data is the same as a normal sync response
  #       @since = id
  #     end
  #   end
  #
  # @see Protocols::CS#sync
  # @see https://github.com/matrix-org/matrix-doc/pull/2108/
  # rubocop:disable Metrics/MethodLength
  def msc2108_sync_sse(since: nil, **params, &on_data)
    raise ArgumentError, 'Must be given a block accepting two args - data and { event:, id: }' \
      unless on_data.is_a?(Proc) && on_data.arity == 2
    raise 'Needs to be logged in' unless access_token # TODO: Better error

    query = params.select do |k, _v|
      %i[filter full_state set_presence].include? k
    end
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    req = Net::HTTP::Get.new(homeserver.dup.tap do |u|
      u.path = api_to_path(:client_r0) + '/sync/sse'
      u.query = URI.encode_www_form(query)
    end)
    req['accept'] = 'text/event-stream'
    req['accept-encoding'] = 'identity' # Disable compression on the SSE stream
    req['authorization'] = "Bearer #{access_token}"
    req['last-event-id'] = since if since

    cancellation_token = { run: true }

    # rubocop:disable Metrics/BlockLength
    thread = Thread.new(cancellation_token) do |ctx|
      print_http(req)
      http.request req do |response|
        break unless ctx[:run]

        print_http(response, body: false)
        raise MatrixRequestError.new_by_code(JSON.parse(response.body, symbolize_names: true), response.code) unless response.is_a? Net::HTTPSuccess

        # Override buffer size for BufferedIO
        socket = response.instance_variable_get :@socket
        if socket.is_a? Net::BufferedIO
          socket.instance_eval do
            def rbuf_fill
              bufsize_override = 1024
              loop do
                case rv = @io.read_nonblock(bufsize_override, exception: false)
                when String
                  @rbuf << rv
                  rv.clear
                  return
                when :wait_readable
                  @io.to_io.wait_readable(@read_timeout) || raise(Net::ReadTimeout)
                when :wait_writable
                  @io.to_io.wait_writable(@read_timeout) || raise(Net::ReadTimeout)
                when nil
                  raise EOFError, 'end of file reached'
                end
              end
            end
          end
        end

        logger.debug 'MSC2108: Starting SSE stream.'

        buffer = ''
        response.read_body do |chunk|
          buffer += chunk

          while (index = buffer.index(/\r\n\r\n|\n\n/))
            stream = buffer.slice!(0..index)

            data = ''
            event = nil
            id = nil

            stream.split(/\r?\n/).each do |part|
              /^data:(.+)$/.match(part) do |m_data|
                data += "\n" unless data.empty?
                data += m_data[1].strip
              end
              /^event:(.+)$/.match(part) do |m_event|
                event = m_event[1].strip
              end
              /^id:(.+)$/.match(part) do |m_id|
                id = m_id[1].strip
              end
              /:(.+)$/.match(part) do |m_comment|
                logger.debug "MSC2108: Received comment '#{m_comment[1].strip}'"
              end
            end

            next unless %w[sync].include? event

            data = JSON.parse(data, symbolize_names: true)
            yield((MatrixSdk::Response.new self, data), event: event, id: id)
          end

          unless ctx[:run]
            socket.close
            break
          end
        end
        break unless ctx[:run]
      end
    end
    # rubocop:enable Metrics/BlockLength

    thread.run

    [thread, cancellation_token]
  end
  # rubocop:enable Metrics/MethodLength
end
