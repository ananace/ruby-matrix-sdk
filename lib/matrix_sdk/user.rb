# frozen_string_literal: true

require 'matrix_sdk'

module MatrixSdk
  # A class for tracking information about a user on Matrix
  class User
    extend MatrixSdk::Extensions

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

    # @return [String] the display name
    # @see MatrixSdk::Protocols::CS#get_display_name
    def display_name
      @display_name ||= client.api.get_display_name(id)[:displayname]
    end

    # @param name [String] the display name to set
    # @see MatrixSdk::Protocols::CS#set_display_name
    def display_name=(name)
      client.api.set_display_name(id, name)
      @display_name = name
    end

    # Gets a friendly name of the user
    # @return [String] either the display name or MXID if unset
    def friendly_name
      display_name || id
    end

    # Gets the avatar for the user
    #
    # @see MatrixSdk::Protocols::CS#get_avatar_url
    def avatar_url
      @avatar_url ||= client.api.get_avatar_url(id)[:avatar_url]
    end

    # Set a new avatar for the user
    #
    # Only works for the current user object, as requested by
    #     client.get_user(:self)
    #
    # @param url [String,URI::MXC] the new avatar URL
    # @note Requires a mxc:// URL, check example on
    #   {MatrixSdk::Protocols::CS#set_avatar_url} for how this can be done
    # @see MatrixSdk::Protocols::CS#set_avatar_url
    def avatar_url=(url)
      client.api.set_avatar_url(id, url)
      @avatar_url = url
    end

    # Get the user's current presence status
    #
    # @return [Symbol] One of :online, :offline, :unavailable
    # @see MatrixSdk::Protocols::CS#get_presence_status
    # @note This information is not cached in the abstraction layer
    def presence
      raw_presence[:presence]&.to_sym
    end

    # Sets the user's current presence status
    # Should be one of :online, :offline, or :unavailable
    #
    # @param new_presence [:online,:offline,:unavailable] The new presence status to set
    # @see MatrixSdk::Protocols::CS#set_presence_status
    def presence=(new_presence)
      raise ArgumentError, 'Presence must be one of :online, :offline, :unavailable' unless %i[online offline unavailable].include?(presence)

      client.api.set_presence_status(id, new_presence)
    end

    # @return [Boolean] if the user is currently active
    # @note This information is not cached in the abstraction layer
    def active?
      raw_presence[:currently_active] == true
    end

    # Gets the user-specified status message - if any
    #
    # @see MatrixSdk::Protocols::CS#get_presence_status
    # @note This information is not cached in the abstraction layer
    def status_msg
      raw_presence[:status_msg]
    end

    # Sets the user-specified status message
    #
    # @param message [String,nil] The message to set, or nil for no message
    # @see MatrixSdk::Protocols::CS#set_presence_status
    def status_msg=(message)
      client.api.set_presence_status(id, presence, message: message)
    end

    # Gets the last time the user was active at, from the server's side
    #
    # @return [Time] when the user was last active
    # @see MatrixSdk::Protocols::CS#get_presence_status
    # @note This information is not cached in the abstraction layer
    def last_active
      since = raw_presence[:last_active_ago]
      return unless since

      Time.now - (since / 1000)
    end

    # Gets a direct message room with the user if one exists
    #
    # @return [Room,nil] A direct message room if one exists
    # @see MatrixSdk::Client#direct_room
    def direct_room
      client.direct_room(id)
    end

    # Returns all the current device keys for the user, retrieving them if necessary
    def device_keys
      @device_keys ||= client.api.keys_query(device_keys: { id => [] }).yield_self do |resp|
        resp.dig(:device_keys, id.to_sym)
      end
    end

    private

    def raw_presence
      client.api.get_presence_status(id).tap { |h| h.delete :user_id }
    end
  end
end
