# frozen_string_literal: true

require 'matrix_sdk/util/tinycache_adapter'

module MatrixSdk::Util
  module Tinycache
    CACHE_LEVELS = {
      none: 0,
      some: 1,
      all: 2
    }.freeze

    def self.adapter
      @adapter ||= TinycacheAdapter
    end

    def self.adapter=(adapter)
      @adapter = adapter
    end

    def self.extended(base)
      helper_name = base.send(:cache_helper_module_name)
      base.send :remove_const, helper_name if base.const_defined?(helper_name)
      base.prepend base.const_set(helper_name, Module.new)

      base.include InstanceMethods
    end

    def cached(*methods, **opts)
      methods.each { |method| build_cache_methods(method, **opts) }
    end

    module InstanceMethods
      def tinycache_adapter
        @tinycache_adapter ||= Tinycache.adapter.new.tap do |adapter|
          adapter.config = self.class.tinycache_adapter_config if adapter.respond_to? :config=
          adapter.client = client if respond_to?(:client) && adapter.respond_to?(:client=)
        end
      end
    end

    def tinycache_adapter_config
      @tinycache_adapter_config ||= {}
    end

    private

    def default_cache_key
      proc do |method_name, _method_args|
        method_name.to_sym
      end
    end

    def cache_helper_module_name
      class_name = name&.gsub(/:/, '') || to_s.gsub(/[^a-zA-Z_0-9]/, '')
      "#{class_name}Tinycache"
    end

    def build_cache_methods(method_name, cache_key: default_cache_key, cache_level: :none, expires_in: nil, **opts)
      raise ArgumentError, 'Cache key must be a three-arg proc' unless cache_key.is_a? Proc

      method_names = build_method_names(method_name)
      tinycache_adapter_config[method_name] = {
        level: cache_level,
        expires: expires_in || 1 * 365 * 24 * 60 * 60 # 1 year
      }

      helper = const_get(cache_helper_module_name)
      return if method_names.any? { |k, _| helper.respond_to? k }

      helper.class_eval do
        define_method(method_names[:cache_key]) do |*args|
          cache_key.call(method_name, args)
        end

        define_method(method_names[:with_cache]) do |*args|
          tinycache_adapter.fetch(__send__(method_names[:cache_key], *args), expires_in: expires_in) do
            __send__(method_names[:without_cache], *args)
          end
        end

        define_method(method_names[:without_cache]) do |*args|
          orig = method(method_name).super_method
          orig.call(*args)
        end

        define_method(method_names[:clear_cache]) do |*args|
          tinycache_adapter.delete(__send__(method_names[:cache_key], *args))
        end

        define_method(method_names[:cached]) do
          true
        end

        define_method(method_names[:has_value]) do |*args|
          tinycache_adapter.valid?(__send__(method_names[:cache_key], *args))
        end

        define_method(method_name) do |*args|
          unless_proc = opts[:unless].is_a?(Symbol) ? opts[:unless].to_proc : opts[:unless]

          skip_cache = false
          skip_cache ||= unless_proc&.call(self, method_name, args)
          skip_cache ||= CACHE_LEVELS[client&.cache || :all] < CACHE_LEVELS[cache_level]

          if skip_cache
            __send__(method_names[:without_cache], *args)
          else
            __send__(method_names[:with_cache], *args)
          end
        end
      end
    end

    def build_method_names(method)
      # Clean up method name (split any suffix)
      method_name = method.to_s.sub(/([?!=])$/, '')
      punctuation = Regexp.last_match(-1)

      {
        cache_key: "#{method_name}_cache_key#{punctuation}",
        with_cache: "#{method_name}_with_cache#{punctuation}",
        without_cache: "#{method_name}_without_cache#{punctuation}",
        clear_cache: "clear_#{method_name}_cache#{punctuation}",
        cached: "#{method}_cached?",
        has_value: "#{method}_has_value?"
      }
    end
  end
end
