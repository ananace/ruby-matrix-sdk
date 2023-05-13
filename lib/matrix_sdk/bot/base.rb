# frozen_string_literal: true

require 'shellwords'

module MatrixSdk::Bot
  class Base
    extend MatrixSdk::Extensions

    RequestHandler = Struct.new('RequestHandler', :command, :type, :proc, :data) do
      def command?
        type == :command
      end

      def event?
        type == :event
      end

      def arity
        arity = self.proc.parameters.count { |t, _| %i[opt req].include? t }
        arity = -arity if self.proc.parameters.any? { |t, _| t.to_s.include? 'rest' }
        arity
      end
    end

    attr_reader :client, :event
    attr_writer :logger

    ignore_inspect :client

    def initialize(hs_url, **params)
      @client = case hs_url
                when MatrixSdk::Api
                  MatrixSdk::Client.new hs_url
                when MatrixSdk::Client
                  hs_url
                when %r{^https?://.*}
                  MatrixSdk::Client.new hs_url, **params
                else
                  MatrixSdk::Client.new_for_domain hs_url, **params
                end

      @client.on_event.add_handler { |ev| _handle_event(ev) }
      @client.on_invite_event.add_handler do |ev|
        break unless settings.accept_invites?

        logger.info "Received invite to #{ev[:room_id]}, joining."
        client.join_room(ev[:room_id])
      end

      @event = nil

      logger.warn 'The bot abstraction is not fully finalized and can be expected to change.'
    end

    def logger
      return @logger if instance_variable_defined?(:@logger) && @logger

      self.class.logger
    end

    def self.logger
      Logging.logger[self].tap do |l|
        begin
          l.level = :debug if MatrixSdk::Bot::PARAMS_CONFIG[:logging]
        rescue NameError
          # Not running as instance
        end
        l.level = settings.log_level unless settings.logging?
      end
    end

    # Register a command during runtime
    #
    # @param command [String] The command to register
    # @see Base.command for full parameter information
    def register_command(command, **params, &block)
      self.class.command(command, **params, &block)
    end

    # Register an event during runtime
    #
    # @param event [String] The event to register
    # @see Base.event for full parameter information
    def register_event(event, **params, &block)
      self.class.event(event, **params, &block)
    end

    # Removes a registered command during runtime
    #
    # @param command [String] The command to remove
    # @see Base.remove_command
    def unregister_command(command)
      self.class.remove_command(command)
    end

    # Removes a registered event during runtime
    #
    # @param event [String] The event to remove
    # @see Base.remove_event
    def unregister_event(command)
      self.class.remove_event(command)
    end

    # Gets the handler for a command
    #
    # @param command [String] The command to retrieve
    # @return [RequestHandler] The registered command handler
    # @see Base.get_command
    def get_command(command, **params)
      self.class.get_command(command, **params)
    end

    # Gets the handler for an event
    #
    # @param event [String] The event to retrieve
    # @return [RequestHandler] The registered event handler
    # @see Base.get_event
    def get_event(event, **params)
      self.class.get_event(event, **params)
    end

    # Checks for the existence of a command
    #
    # @param command [String] The command to check
    # @see Base.command?
    def command?(command, **params)
      self.class.command?(command, **params)
    end

    # Checks for the existence of a handled event
    #
    # @param event [String] The event to check
    # @see Base.event?
    def event?(event, **params)
      self.class.event?(event, **params)
    end

    # Access settings defined with Base.set
    def settings
      self.class.settings
    end

    # Access settings defined with Base.set
    def self.settings
      self
    end

    class << self
      attr_reader :handlers

      CALLERS_TO_IGNORE = [
        /\/matrix_sdk\/.+\.rb$/,                            # all MatrixSdk code
        /^\(.*\)$/,                                         # generated code
        /rubygems\/(custom|core_ext\/kernel)_require\.rb$/, # rubygems require hacks
        /bundler(\/(?:runtime|inline))?\.rb/,               # bundler require hacks
        /<internal:/                                        # internal in ruby >= 1.9.2
      ].freeze

      # A filter that should only result in a valid sync token and no other data
      EMPTY_BOT_FILTER = {
        account_data: { types: [] },
        event_fields: [],
        presence: { types: [] },
        room: {
          account_data: { types: [] },
          ephemeral: { types: [] },
          state: {
            types: [],
            lazy_load_members: true
          },
          timeline: {
            types: []
          }
        }
      }.freeze

      # Reset the bot class, removing any local handlers that have been registered
      def reset!
        @handlers = {}
        @client_handler = nil
      end

      # Retrieves all registered - including inherited - handlers for the bot
      #
      # @param type [:command,:event,:all] Which handler type to return, or :all to return all handlers regardless of type
      # @return [Array[RequestHandler]] The registered handlers for the bot and parents
      def all_handlers(type: :command)
        parent = superclass&.all_handlers(type: type) if superclass.respond_to? :all_handlers
        (parent || {}).merge(@handlers.select { |_, h| type == :all || h.type == type }).compact
      end

      # Set a class-wide option for the bot
      #
      # @param option [Symbol,Hash] The option/options to set
      # @param value [Proc,Symbol,Integer,Boolean,Hash,nil] The value to set for the option, should be ignored if option is a Hash
      # @param ignore_setter [Boolean] Should any existing setter method be ignored during assigning of the option
      # @yieldreturn The value that the option should return when requested, as an alternative to passing the Proc as value
      def set(option, value = (not_set = true), ignore_setter = false, &block) # rubocop:disable Style/OptionalBooleanParameter
        raise ArgumentError if block && !not_set

        if block
          value = block
          not_set = false
        end

        if not_set
          raise ArgumentError unless option.respond_to?(:each)

          option.each { |k, v| set(k, v) }
          return self
        end

        return send("#{option}=", value) if respond_to?("#{option}=") && !ignore_setter

        setter = proc { |val| set option, val, true }
        getter = proc { value }

        case value
        when Proc
          getter = value
        when Symbol, Integer, FalseClass, TrueClass, NilClass
          getter = value.inspect
        when Hash
          setter = proc do |val|
            val = value.merge val if val.is_a? Hash
            set option, val, true
          end
        end

        define_singleton("#{option}=", setter)
        define_singleton(option, getter)
        define_singleton("#{option}?", "!!#{option}") unless method_defined? "#{option}?"
        self
      end

      # Same as calling `set :option, true` for each of the given options.
      #
      # @param opts [Array[Symbol]] The options to set to true
      def enable(*opts)
        opts.each { |key| set(key, true) }
      end

      # Same as calling `set :option, false` for each of the given options.
      #
      # @param opts [Array[Symbol]] The options to set to false
      def disable(*opts)
        opts.each { |key| set(key, false) }
      end

      # Register a bot command
      #
      # @note Due to the way blocks are handled, required parameters won't block execution.
      #   If your command requires all parameters to be valid, you will need to check for nil yourself.
      #
      # @note Execution will be performed with a MatrixSdk::Bot::Request object as self.
      #   To access the bot instance, use MatrixSdk::Bot::Request#bot
      #
      # @param command [String] The command to register, will be routed based on the prefix and bot NameError
      # @param desc [String] A human-readable description for the command
      # @param only [Symbol,Proc,Array[Symbol,Proc]] What limitations does this command have?
      #   Can use :DM, :Admin, :Mod
      # @option params
      def command(command, desc: nil, notes: nil, only: nil, **params, &block)
        args = params[:args] || convert_to_lambda(&block).parameters.map do |type, name|
          case type
          when :req
            name.to_s.upcase
          when :opt
            "[#{name.to_s.upcase}]"
          when :rest
            "[#{name.to_s.upcase}...]"
          end
        end.compact.join(' ')

        logger.debug "Registering command #{command} with args #{args}"

        add_handler(
          command.to_s.downcase,
          type: :command,
          args: args,
          desc: desc,
          notes: notes,
          only: [only].flatten.compact,
          &block
        )
      end

      # Register a Matrix event
      #
      # @note Currently it's only possible to register one handler per event type
      #
      # @param event [String] The ID for the event to register
      # @param only [Symbol,Proc,Array[Symbol,Proc]] The limitations to when the event should be handled
      # @option params
      def event(event, only: nil, **_params, &block)
        logger.debug "Registering event #{event}"

        add_handler(
          event.to_s,
          type: :event,
          only: [only].flatten.compact,
          &block
        )
      end

      # Registers a block to be run when configuring the client, before starting the sync
      def client(&block)
        @client_handler = block
      end

      # Check if a command is registered
      #
      # @param command [String] The command to check
      # @param ignore_inherited [Booleen] Should the check ignore any inherited commands and only check local registrations
      def command?(command, ignore_inherited: false)
        return @handlers[command.to_s.downcase]&.command? if ignore_inherited

        all_handlers[command.to_s.downcase]&.command? || false
      end

      # Check if an event is registered
      #
      # @param event [String] The event type to check
      # @param ignore_inherited [Booleen] Should the check ignore any inherited events and only check local registrations
      def event?(event, ignore_inherited: false)
        return @handlers[event]&.event? if ignore_inherited

        all_handlers(type: :event)[event]&.event? || false
      end

      # Retrieves the RequestHandler for a given command
      #
      # @param command [String] The command to retrieve
      # @param ignore_inherited [Booleen] Should the retrieval ignore any inherited commands and only check local registrations
      # @return [RequestHandler,nil] The registered handler for the command if any
      def get_command(command, ignore_inherited: false)
        if ignore_inherited && @handlers[command]&.command?
          @handlers[command]
        elsif !ignore_inherited && all_handlers[command]&.command?
          all_handlers[command]
        end
      end

      # Retrieves the RequestHandler for a given event
      #
      # @param event [String] The event type to retrieve
      # @param ignore_inherited [Booleen] Should the retrieval ignore any inherited events and only check local registrations
      # @return [RequestHandler,nil] The registered handler for the event if any
      def get_event(event, ignore_inherited: false)
        if ignore_inherited && @handlers[event]&.event?
          @handlers[event]
        elsif !ignore_inherited && all_handlers(type: :event)[event]&.event?
          all_handlers(type: :event)[event]
        end
      end

      # Removes a registered command from the bot
      #
      # @note This will only affect local commands, not ones inherited
      # @param command [String] The command to remove
      def remove_command(command)
        return false unless @handlers[command]&.command?

        @handers.delete command
        true
      end

      # Removes a registered event from the bot
      #
      # @note This will only affect local event, not ones inherited
      # @param event [String] The event to remove
      def remove_event(event)
        return false unless @handlers[event]&.event?

        @handers.delete event
        true
      end

      # Stops any running instance of the bot
      def quit!
        return unless running?

        active_bot.logger.info "Stopping #{settings.bot_name}..."

        if settings.store_sync_token
          begin
            active_bot.client.api.set_account_data(
              active_bot.client.mxid, "dev.ananace.ruby-sdk.#{settings.bot_name}",
              { sync_token: active_bot.client.sync_token }
            )
          rescue StandardError => e
            active_bot.logger.error "Failed to save sync token, #{e.class}: #{e}"
          end
        end

        active_bot.client.logout if login?

        active_bot.client.api.stop_inflight
        active_bot.client.stop_listener_thread

        set :active_bot, nil
      end

      # Starts the bot up
      #
      # @param options [Hash] Settings to apply using Base.set
      def run!(options = {}, &block)
        return if running?

        set options

        bot_settings = settings.respond_to?(:bot_settings) ? settings.bot_settings : {}
        bot_settings.merge!(
          threadsafe: settings.threadsafe,
          client_cache: settings.client_cache,
          sync_filter: settings.sync_filter
        )

        bot_settings[:auth] = if settings.access_token?
                                { access_token: settings.access_token }
                              else
                                { username: settings.username, password: settings.password }
                              end

        begin
          start_bot(bot_settings, &block)
        ensure
          quit!
        end
      end

      # Check whether the self-hosted server is running or not.
      def running?
        active_bot?
      end

      private

      def add_handler(command, type:, **data, &block)
        @handlers[command] = RequestHandler.new command.to_s.downcase, type, block, data.compact
      end

      def start_bot(bot_settings, &block)
        cl = if homeserver =~ %r{^https?://}
               MatrixSdk::Client.new homeserver
             else
               MatrixSdk::Client.new_for_domain homeserver
             end

        auth = bot_settings.delete :auth
        bot = new cl, **bot_settings
        bot.logger.level = settings.log_level
        bot.logger.info "Starting #{settings.bot_name}..."

        if settings.login?
          bot.client.login auth[:username], auth[:password], no_sync: true
        else
          bot.client.access_token = auth[:access_token]
        end

        set :active_bot, bot

        if @client_handler
          case @client_handler.arity
          when 0
            bot.client.instance_exec(&@client_handler)
          else
            @client_handler.call(bot.client)
          end
        end
        block&.call bot

        if settings.sync_token?
          bot.client.instance_variable_set(:@next_batch, settings.sync_token)
        elsif settings.store_sync_token?
          begin
            data = bot.client.api.get_account_data(bot.client.mxid, "dev.ananace.ruby-sdk.#{bot_name}")
            bot.client.sync_token = data[:sync_token]
          rescue MatrixSdk::MatrixNotFoundError
            # Valid
          rescue StandardError => e
            bot.logger.error "Failed to restore old sync token, #{e.class}: #{e}"
          end
        else
          bot.client.sync(filter: EMPTY_BOT_FILTER)
        end

        bot.client.start_listener_thread

        bot.client.instance_variable_get(:@sync_thread).join
      rescue Interrupt
        # Happens when killed
      rescue StandardError => e
        logger.fatal "Failed to start #{settings.bot_name} - #{e.class}: #{e}"
        raise
      end

      def define_singleton(name, content = Proc.new)
        singleton_class.class_eval do
          undef_method(name) if method_defined? name
          content.is_a?(String) ? class_eval("def #{name}() #{content}; end", __FILE__, __LINE__) : define_method(name, &content)
        end
      end

      # Helper to convert a proc to a non-callable lambda
      #
      # This method is only used to get a correct parameter list, the resulting lambda is invalid and can't be used to actually execute a call
      def convert_to_lambda(this: nil, &block)
        return block if block.lambda?

        this ||= Object.new
        this.define_singleton_method(:_, &block)
        this.method(:_).to_proc
      end

      def cleaned_caller(keep = 3)
        caller(1)
          .map!   { |line| line.split(/:(?=\d|in )/, 3)[0, keep] }
          .reject { |file, *_| CALLERS_TO_IGNORE.any? { |pattern| file =~ pattern } }
      end

      def caller_files
        cleaned_caller(1).flatten
      end

      def inherited(subclass)
        subclass.reset!
        subclass.set :app_file, caller_files.first unless subclass.app_file?
        super
      end
    end

    def command_allowed?(command, event)
      pre_event = @event

      return false unless command? command

      handler = get_command(command)
      return true if (handler.data[:only] || []).empty?

      # Avoid modifying input data for a checking method
      @event = MatrixSdk::Response.new(client.api, event.dup)
      return false if [handler.data[:only]].flatten.compact.any? do |only|
        if only.is_a? Proc
          !instance_exec(&only)
        else
          case only.to_s.downcase.to_sym
          when :dm
            !room.dm?(members_only: true)
          when :admin
            !sender_admin?
          when :mod
            !sender_moderator?
          end
        end
      end

      true
    ensure
      @event = pre_event
    end

    def event_allowed?(event)
      pre_event = @event

      return false unless event? event[:type]

      handler = get_event(event[:type])
      return true if (handler.data[:only] || []).empty?

      # Avoid modifying input data for a checking method
      @event = MatrixSdk::Response.new(client.api, event.dup)
      return false if [handler.data[:only]].flatten.compact.any? do |only|
        if only.is_a? Proc
          instance_exec(&only)
        else
          case only.to_s.downcase.to_sym
          when :dm
            !room.dm?(members_only: true)
          when :admin
            !sender_admin?
          when :mod
            !sender_moderator?
          end
        end
      end

      true
    ensure
      @event = pre_event
    end

    #
    # Helpers for handling events
    #

    def in_event?
      !@event.nil?
    end

    def bot
      self
    end

    def room
      client.ensure_room(event[:room_id]) if in_event?
    end

    def sender
      client.get_user(event[:sender]) if in_event?
    end

    # Helpers for checking power levels
    def sender_admin?
      sender&.admin? room
    end

    def sender_moderator?
      sender&.moderator? room
    end

    #
    # Helpers
    #

    def expanded_prefix
      return "#{settings.command_prefix}#{settings.bot_name} " if settings.bot_name?

      settings.command_prefix
    end

    private

    #
    # Event handling
    #

    # TODO: Add handling results - Ok, NoSuchCommand, NotAllowed, etc
    def _handle_event(event)
      return if in_event?
      return if settings.ignore_own? && client.mxid == event[:sender]

      event = event.data if event.is_a? MatrixSdk::MatrixEvent

      logger.debug "Received event #{event}"
      return _handle_message(event) if event[:type] == 'm.room.message'
      return unless event?(event[:type])

      handler = get_event(event[:type])
      return unless event_allowed? event

      logger.info "Handling event #{event[:sender]}/#{event[:room_id]} => #{event[:type]}"

      clean_event = MatrixSdk::Response.new(client.api, event)
      arity = handler.arity
      case arity
      when 0
        @event = clean_event
        instance_exec(&handler.proc)
      else
        instance_exec(clean_event, &handler.proc)
      end
    # Argument errors are likely to be a "friendly" error, so don't direct the user to the log
    rescue ArgumentError => e
      logger.error "#{e.class} when handling #{event[:type]}: #{e}\n#{e.backtrace[0, 10].join("\n")}"
      room.send_notice("Failed to handle event of type #{event[:type]} - #{e}.")
    rescue StandardError => e
      puts e, e.backtrace if settings.respond_to?(:testing?) && settings.testing?
      logger.error "#{e.class} when handling #{event[:type]}: #{e}\n#{e.backtrace[0, 10].join("\n")}"
      room.send_notice("Failed to handle event of type #{event[:type]} - #{e}.\nMore information is available in the bot logs")
    ensure
      @event = nil
    end

    def _handle_message(event)
      return if in_event?
      return if settings.ignore_own? && client.mxid == event[:sender]

      type = event[:content][:msgtype]
      return unless settings.allowed_types.include? type

      message = event[:content][:body].dup

      room = client.ensure_room(event[:room_id])
      if room.dm?(members_only: true)
        unless message.start_with? settings.command_prefix
          prefix = expanded_prefix || settings.command_prefix
          message.prepend prefix unless message.start_with? prefix
        end
      else
        return if settings.require_fullname? && !message.start_with?(expanded_prefix)
        return unless message.start_with? settings.command_prefix
      end

      if message.start_with?(expanded_prefix)
        message.sub!(expanded_prefix, '')
      else
        message.sub!(settings.command_prefix, '')
      end

      parts = message.shellsplit
      command = parts.shift.downcase

      message.sub!(command, '')
      message.lstrip!

      handler = get_command(command)
      return unless handler
      return unless command_allowed?(command, event)

      logger.info "Handling command #{event[:sender]}/#{event[:room_id]}: #{settings.command_prefix}#{command}"

      @event = MatrixSdk::Response.new(client.api, event)
      arity = handler.arity
      case arity
      when 0
        instance_exec(&handler.proc)
      when 1
        message = message.sub("#{settings.command_prefix}#{command}", '').lstrip
        message = nil if message.empty?

        # TODO: What's the most correct way to handle messages with quotes?
        # XXX   Currently all quotes are kept

        instance_exec(message, &handler.proc)
      else
        instance_exec(*parts, &handler.proc)
      end
    # Argument errors are likely to be a "friendly" error, so don't direct the user to the log
    rescue ArgumentError => e
      logger.error "#{e.class} when handling #{settings.command_prefix}#{command}: #{e}\n#{e.backtrace[0, 10].join("\n")}"
      room.send_notice("Failed to handle #{command} - #{e}.")
    rescue StandardError => e
      puts e, e.backtrace if settings.respond_to?(:testing?) && settings.testing?
      logger.error "#{e.class} when handling #{settings.command_prefix}#{command}: #{e}\n#{e.backtrace[0, 10].join("\n")}"
      room.send_notice("Failed to handle #{command} - #{e}.\nMore information is available in the bot logs")
    ensure
      @event = nil
    end

    #
    # Default configuration
    #

    reset!

    ## Bot configuration
    # Should the bot automatically accept invites
    set :accept_invites, true
    # What character should commands be prefixed with
    set :command_prefix, '!'
    # What's the name of the bot - used for non 1:1 rooms and sync-token storage
    set(:bot_name) { File.basename $PROGRAM_NAME, '.*' }
    # Which msgtypes should the bot listen for when handling commands
    set :allowed_types, %w[m.text]
    # Should the bot ignore its own events
    set :ignore_own, true
    # Should the bot require full-name commands in non-DM rooms?
    set :require_fullname, false
    # Sets a text to display before the usage information in the built-in help command
    set :help_preamble, nil
    # Should the bot automaticall follow tombstone events, when rooms are upgraded
    set :follow_tombstones, true

    ## Sync token handling
    # Token specified by the user
    set :sync_token, nil
    # Token automatically stored in an account_data key
    set :store_sync_token, false

    # Homeserver, either domain or URL
    set :homeserver, 'matrix.org'
    # Which level of thread safety should be used
    set :threadsafe, :multithread

    ## User authorization
    # Existing access token
    set :access_token, nil
    # Username for a per-instance login
    set :username, nil
    # Password for a per-instance login
    set :password, nil

    # Helper to check if a login is requested
    set(:login) { username? && password? }

    ## Client abstraction configuration
    # What level of caching is wanted - most bots won't need full client-level caches
    set :client_cache, :some
    # The default sync filter, should be modified to limit to what the bot uses
    set :sync_filter, {
      room: {
        timeline: {
          limit: 20
        },
        state: {
          lazy_load_members: true
        }
      }
    }

    ## Logging configuration
    # Should logging be enabled? (Will always log fatal errors)
    set :logging, false
    # What level of logging should the bot use
    set :log_level, :info

    ## Internal configuration values
    set :app_file, nil
    set :active_bot, nil

    #
    # Default commands
    #

    # Displays an usage information text, listing all available commands as well as their arguments
    command(
      :help,
      desc: 'Shows this help text',
      notes: <<~NOTES
        For commands that take multiple arguments, you will need to use quotes around spaces
        E.g. !login "my username" "this is not a real password"
      NOTES
    ) do |command = nil|
      logger.debug "Handling request for built-in help for #{sender}" if command.nil?
      logger.debug "Handling request for built-in help for #{sender} on #{command.inspect}" unless command.nil?

      commands = self.class.all_handlers
      commands.select! { |c, _| c.include? command } if command
      commands.select! { |c, _| command_allowed? c, event }

      commands = commands.map do |_cmd, handler|
        info = handler.data[:args]
        info += " - #{handler.data[:desc]}" if handler.data[:desc]
        info += "\n  #{handler.data[:notes].split("\n").join("\n  ")}" if !command.nil? && handler.data[:notes]
        info = nil if info.empty?

        [
          room.dm? ? "#{settings.command_prefix}#{handler.command}" : "#{expanded_prefix}#{handler.command}",
          info
        ].compact
      end

      commands = commands.map { |*args| args.join(' ') }.join("\n")
      if command
        if commands.empty?
          room.send_notice("No information available on #{command}")
        else
          room.send_notice("Help for #{command};\n#{commands}")
        end
      else
        room.send_notice("#{settings.help_preamble? ? "#{settings.help_preamble}\n\n" : ''}Usage:\n\n#{commands}")
      end
    end

    #
    # Default events
    #

    event('m.room.tombstone', only: -> { follow_tombstones }) do |tombstone|
      logger.info "Received tombstone, following: #{tombstone.content.body}"
      client.join_room tombstone.content.replacement_room
    end
  end
end
