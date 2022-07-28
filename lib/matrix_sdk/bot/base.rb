# frozen_string_literal: true

require 'matrix_sdk'
require 'matrix_sdk/bot/request'
require 'shellwords'

module MatrixSdk::Bot
  class Base
    extend MatrixSdk::Extensions
    include MatrixSdk::Logging

    RequestHandler = Struct.new('RequestHandler', :command, :proc, :data)

    attr_reader :client

    ignore_inspect :client

    def initialize(hs_url, **params)
      @client = if hs_url.is_a? MatrixSdk::Client
                  hs_url
                else
                  MatrixSdk::Client.new hs_url, **params
                end

      @client.on_event.add_handler('m.room.message') { |ev| _handle_event(ev) }
      @client.on_invite_event.add_handler { |ev| client.join_room(ev[:room_id]) if settings.accept_invites? }
    end

    # Access settings defined with Base.set.
    def self.settings
      self
    end

    # Access settings defined with Base.set.
    def settings
      self.class.settings
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

      def set(option, value = (not_set = true), ignore_setter = false, &block)
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

      def command(command, **params, &block)
        args = params[:args] || block.parameters.map do |type, name|
          case type
          when :req
            name.to_s.upcase
          when :opt
            "[#{name.to_s.upcase}]"
          when :rest
            "[#{name.to_s.upcase}...]"
          end
        end.join(' ')
        desc = params[:desc]

        add_handler command.to_s.downcase, args: args, desc: desc, &block
      end

      def client(&block)
        @client_handler = block
      end

      def quit!
        return unless running?

        active_bot.client.logout if login?
        active_bot.client.stop_listener_thread

        set :active_bot, nil
      end

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
        bot.logger.level = settings.log_level
        bot.logger.info 'Starting new instance'

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
        else
          bot.client.sync(filter: EMPTY_BOT_FILTER)
        end

        bot.client.start_listener_thread

        bot.client.instance_variable_get(:@sync_thread).join
      rescue Interrupt
        # Happens when killed
      end

      def define_singleton(name, content = Proc.new)
        singleton_class.class_eval do
          undef_method(name) if method_defined? name
          content.is_a?(String) ? class_eval("def #{name}() #{content}; end", __FILE__, __LINE__) : define_method(name, &content)
        end
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

    #
    # Event handling
    #

    def _handle_event(event)
      return if settings.ignore_own && client.mxid == event[:sender]

      logger.debug "Received event #{event}"

      type = event[:content][:msgtype]
      return unless settings.allowed_types.include? type

      message = event[:content][:body]

      expanded_prefix = "#{settings.command_prefix}#{settings.bot_name} " if settings.bot_name
      room = client.ensure_room(event[:room_id])

      if room.direct?
        logger.debug 'Is direct room'
        room.direct = true
        unless message.start_with? settings.command_prefix
          prefix = expanded_prefix || settings.command_prefix
          message.prepend prefix unless message.start_with? prefix
        end
      else
        return unless message.start_with? settings.command_prefix
      end

      if expanded_prefix && message.start_with?(expanded_prefix)
        message.sub!(expanded_prefix, '')
      else
        message.sub!(settings.command_prefix, '')
      end

      parts = message.shellsplit
      command = parts.shift.downcase

      message.sub!(command, '')
      message.lstrip!

      handler = self.class.all_handlers[command]
      return unless handler

      arity = handler.proc.parameters.count { |t, _| %i[opt req].include? t }
      arity = -arity if handler.proc.parameters.any? { |t, _| t.to_s.include? 'rest' }

      logger.debug "Command has handler #{handler}, with arity #{arity}"

      req = MatrixSdk::Bot::Request.new self, event
      req.logger = Logging.logger[self]
      case arity
      when 0
        req.instance_exec(&handler.proc)
      when 1
        message = message.sub("#{settings.command_prefix}#{command}", '').lstrip
        message = nil if message.empty?

        req.instance_exec(message, &handler.proc)
      else
        req.instance_exec(*parts, &handler.proc)
      end
    rescue StandardError => e
      logger.error "#{e.class} when handling #{settings.command_prefix}#{command}: #{e}\n#{e.backtrace[0, 10].join("\n")}"
    end

    #
    # Default configuration
    #

    reset!

    set :app_file, nil
    set :sync_token, nil

    set :homeserver, 'matrix.org'
    set :threadsafe, true

    set :access_token, nil
    set :username, nil
    set :password, nil

    set(:login) { username? && password? }

    set :client_cache, :some
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

    set :logging, false
    set :log_level, :info

    set :accept_invites, true
    set :command_prefix, '!'
    set :bot_name, nil
    set :allowed_types, %w[m.text]
    set :ignore_own, true

    command(:help, desc: 'Shows this help text') do |command = nil|
      logger.info "Received request for help on #{command.inspect}"

      commands = bot.class.all_handlers
      commands.select! { |c| c.include? command } if command

      commands = commands.map do |_cmd, handler|
        ["#{bot.settings.command_prefix}#{handler.command}", handler.data[:args]].compact.join(' ') + " - #{handler.data[:desc]}"
      end

      if command
        if commands.empty?
          room.send_notice("No information available on #{command.inspect}")
        else
          room.send_notice("Help for #{command.inspect};\n#{commands.join("\n")}")
        end
      else
        room.send_notice("Usage:\n\n#{commands.join("\n")}")
      end
    end
  end

  class Instance < Base
    set :logging, true
    set :log_level, :info

    set :method_override, true
    set :run, true
    set :app_file, nil

    set :active_bot, nil

    def self.register(*extensions, &block) #:nodoc:
      added_methods = extensions.flat_map(&:public_instance_methods)
      Delegator.delegate(*added_methods)
      super(*extensions, &block)
    end
  end

  module Delegator #:nodoc:
    def self.delegate(*methods)
      methods.each do |method_name|
        define_method(method_name) do |*args, &block|
          return super(*args, &block) if respond_to? method_name

          Delegator.target.send(method_name, *args, &block)
        end
        # ensure keyword argument passing is compatible with ruby >= 2.7
        ruby2_keywords(method_name) if respond_to?(:ruby2_keywords, true)
        private method_name
      end
    end

    delegate :command,
             :client, :settings,
             :set, :enable, :disable

    class << self
      attr_accessor :target
    end

    self.target = Instance
  end
end
