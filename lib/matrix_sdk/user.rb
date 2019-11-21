# frozen_string_literal: true

require 'matrix_sdk'

module MatrixSdk
  # A class for tracking information about a user on Matrix
  class User
    extend MatrixSdk::Extensions

    # @!attribute [r] id
    #   @return [String] the MXID of the user
    # @!attribute [r] client
    #   @return [Client] the client for the user
    attr_reader :id, :client
    alias user_id :id

    # @!method inspect
    #   An inspect method that skips a handful of instance variables to avoid
    #   flooding the terminal with debug data.
    #   @return [String] a regular inspect string without the data for some variables
    ignore_inspect :client

    def initialize(client, id, data = {})
      @client = client
      @id = id

      @display_name = nil
      @avatar_url = nil

      data.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end
    end

    # @!attribute [r] display_name
    # @return [String] the display name
    def display_name
      @display_name ||= client.api.get_display_name(id)[:displayname]
    end

    # @!attribute [w] display_name
    # @param name [String] the display name to set
    def display_name=(name)
      client.api.set_display_name(id, name)
      @display_name = name
    end

    # Gets a friendly name of the user
    # @return [String] either the display name or MXID if unset
    def friendly_name
      display_name || id
    end

    # @!attribute [r] avatar_url
    def avatar_url
      @avatar_url ||= client.api.get_avatar_url(id)[:avatar_url]
    end

    # @!attribute [w] avatar_url
    def avatar_url=(url)
      client.api.set_avatar_url(id, url)
      @avatar_url = url
    end

    # @!attribute[r] presence
    # @note This information is not cached in the abstraction layer
    def presence
      raw_presence[:presence].to_sym
    end

    # @!attribute[w] presence
    def presence=(new_presence)
      raise ArgumentError, 'Presence must be one of :online, :offline, :unavaiable' unless %i[online offline unavailable].include?(presence)

      client.api.set_presence_status(id, new_presence)
    end

    # @return [Boolean] if the user is currently active
    # @note This information is not cached in the abstraction layer
    def active?
      raw_presence[:currently_active] == true
    end

    # @!attribute[r] status_msg
    # @note This information is not cached in the abstraction layer
    def status_msg
      raw_presence[:status_msg]
    end

    # @!attribute[w] status_msg
    def status_msg=(message)
      client.api.set_presence_status(id, presence, message: message)
    end

    # @return [Time] when the user was last active
    # @note This information is not cached in the abstraction layer
    def last_active
      since = raw_presence[:last_active_ago]
      return unless since

      Time.now - (since / 1000)
    end

    def device_keys
      @device_keys ||= client.api.keys_query(device_keys: { id => [] }).yield_self do |resp|
        resp[:device_keys][id.to_sym]
      end
    end

    private

    def raw_presence
      client.api.get_presence_status(id).tap { |h| h.delete :user_id }
    end
  end
end
