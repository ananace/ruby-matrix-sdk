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

    def device_keys
      @device_keys ||= client.api.keys_query(device_keys: { id => [] }).yield_self do |resp|
        resp[:device_keys][id.to_sym]
      end
    end
  end
end
