# frozen_string_literal: true

require 'matrix_sdk/bot/request'
require 'shellwords'

module MatrixSdk::Bot
  class Base
    extend MatrixSdk::Extensions

    RequestHandler = Struct.new('RequestHandler', :command, :proc, :data) do
      def arity
        arity = self.proc.parameters.count { |t, _| %i[opt req].include? t }
        arity = -arity if self.proc.parameters.any? { |t, _| t.to_s.include? 'rest' }
        arity
      end
    end

    attr_reader :client

    ignore_inspect :client

    def initialize(hs_url, **params)
      @client = case hs_url
                when MatrixSdk::Client
                  hs_url
                when %r{^https?://.*}
                  MatrixSdk::Client.new hs_url, **params
                else
                  MatrixSdk::Client.new_for_domain hs_url, **params
                end

      @client.on_event.add_handler('m.room.message') { |ev| _handle_event(ev) }
      @client.on_invite_event.add_handler { |ev| client.join_room(ev[:room_id]) if settings.accept_invites? }
    end

    def expanded_prefix
      return "#{settings.command_prefix}#{settings.bot_name} " if settings.bot_name

      settings.command_prefix
    end

    def logger
      @logger || self.class.logger
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

    # Removes a registered command during runtime
    #
    # @param command [String] The command to remove
    # @see Base.remove_command
    def unregister_command(command)
      self.class.remove_command(command)
    end

    # Gets the handler for a command
    #
    # @param command [String] The command to retrieve
    # @return [RequestHandler] The registered command handler
    # @see Base.get_command
    def get_command(command, **params)
      self.class.get_command(command, **params)
    end

    # Checks for the existence of a command
    #
    # @param command [String] The command to check
    # @see Base.command?
    def command?(command, **params)
      self.class.command?(command, **params)
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

      EMPTY_BOT_FILTER = {
        presence: { types: [] },
        account_data: { types: [] },
        room: {
          ephemeral: { types: [] },
          state: {
            types: [],
            lazy_load_members: true
          },
          timeline: {
            types: []
          },
          account_data: { types: [] }
        }
      }.freeze

      def reset!
        @handlers = {}
        @client_handler = nil
      end

      def all_handlers
        parent = superclass&.all_handlers if superclass.respond_to? :all_handlers
        (parent || {}).merge(@handlers).compact
      end

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
      def enable(*opts)
        opts.each { |key| set(key, true) }
      end

      # Same as calling `set :option, false` for each of the given options.
      def disable(*opts)
        opts.each { |key| set(key, false) }
      end

      def add_handler(command, **data, &block)
        @handlers[command] = RequestHandler.new command.to_s.downcase, block, data.compact
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
          args: args,
          desc: desc,
          notes: notes,
          only: [only].flatten.compact,
          &block
        )
      end

      def command?(command, ignore_inherited: false)
        return @handlers.key? command if ignore_inherited

        all_handlers.key? command
      end

      def get_command(command, ignore_inherited: false)
        if ignore_inherited
          @handlers[command]
        else
          all_handlers[command]
        end
      end

      # Removes a registered command from the bot
      #
      # @note This will only affect local commands, not ones inherited
      # @param command [String] The command to remove
      def remove_command(command)
        return false unless @handlers.key? command

        @handers.delete command
        true
      end

      def client(&block)
        @client_handler = block
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

      def start_bot(bot_settings, &block)
        cl = if homeserver =~ %r{^https?://}
               MatrixSdk::Client.new homeserver
             else
               MatrixSdk::Client.new_for_domain homeserver
             end

        auth = bot_settings.delete :auth
        bot = new cl, **bot_settings
        bot.client.cache = settings.client_cache
        bot.logger.level = settings.log_level
        bot.logger.info "Starting #{settings.bot_name}..."

        if settings.login?
          bot.client.login auth[:username], auth[:password], no_sync: true
        else
          bot.client.access_token = auth[:access_token]
        end

        set :active_bot, bot

        block&.call bot
        @client_handler&.call bot.client

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
      return false unless command? command

      handler = get_command(command)
      return true if (handler.data[:only] || []).empty?

      req = MatrixSdk::Bot::Request.new self, event
      req.logger = Logging.logger[self]
      return false if [handler.data[:only]].flatten.compact.any? do |only|
        if only.is_a? Proc
          req.instance_exec(&only)
        else
          case only.to_s.downcase.to_sym
          when :dm
            !req.room.dm?(members_only: true)
          when :admin
            !req.sender.admin?(room)
          when :mod
            !req.sender.moderator?(room)
          end
        end
      end

      true
    end

    private

    #
    # Event handling
    #

    # TODO: Add handling results - Ok, NoSuchCommand, NotAllowed, etc
    def _handle_event(event)
      return if settings.ignore_own? && client.mxid == event[:sender]

      logger.debug "Received event #{event}"

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

      req = MatrixSdk::Bot::Request.new self, event
      req.logger = Logging.logger[self]

      logger.debug "Handling command #{handler.command}"

      arity = handler.arity
      case arity
      when 0
        req.instance_exec(&handler.proc)
      when 1
        message = message.sub("#{settings.command_prefix}#{command}", '').lstrip
        message = nil if message.empty?

        # TODO: What's the most correct way to handle messages with quotes?
        # XXX   Currently all quotes are kept

        req.instance_exec(message, &handler.proc)
      else
        req.instance_exec(*parts, &handler.proc)
      end
    # Argument errors are likely to be a "friendly" error, so don't direct the user to the log
    rescue ArgumentError => e
      logger.error "#{e.class} when handling #{settings.command_prefix}#{command}: #{e}\n#{e.backtrace[0, 10].join("\n")}"
      room.send_notice("Failed to handle #{command} - #{e}.")
    rescue StandardError => e
      logger.error "#{e.class} when handling #{settings.command_prefix}#{command}: #{e}\n#{e.backtrace[0, 10].join("\n")}"
      room.send_notice("Failed to handle #{command} - #{e}.\nMore information is available in the bot logs")
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

    #
    # Default commands
    #

    command(
      :help,
      desc: 'Shows this help text',
      notes: <<~NOTES
        For commands that include multiple separate arguments, you will need to use quotes where they contain spaces
        E.g. !login "my username" "this is not a real password"
      NOTES
    ) do |command = nil|
      logger.info "Handling request for built-in help for #{sender}" if command.nil?
      logger.info "Handling request for built-in help for #{sender} on #{command.inspect}" unless command.nil?

      commands = bot.class.all_handlers
      commands.select! { |c, _| c.include? command } if command
      commands.select! { |c, _| bot.command_allowed? c, event }

      commands = commands.map do |_cmd, handler|
        info = handler.data[:args]
        info += " - #{handler.data[:desc]}" if handler.data[:desc]
        info += "\n  #{handler.data[:notes].split("\n").join("\n  ")}" if !command.nil? && handler.data[:notes]
        info = nil if info.empty?

        [
          room.dm? ? "#{bot.settings.command_prefix}#{handler.command}" : "#{bot.expanded_prefix}#{handler.command}",
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
        room.send_notice("Usage:\n\n#{commands}")
      end
    end
  end
end
