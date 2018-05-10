require 'matrix_sdk'

module MatrixSdk
  class User
    attr_reader :id, :client

    def initialize(client, id, data = {})
      @client = client
      @id = id

      @display_name = nil
      @avatar_url = nil

      data.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end
    end

    def display_name
      @display_name ||= client.api.get_display_name(id)[:displayname]
    end

    def display_name=(name)
      client.api.set_display_name(id, name)
      @display_name = name
    rescue MatrixError
      nil
    end

    def friendly_name
      display_name || id
    end

    def avatar_url
      @avatar_url ||= client.api.get_avatar_url(id)[:avatar_url]
    end

    def avatar_url=(url)
      client.api.set_avatar_url(id, url)
      @avatar_url = url
    rescue MatrixError
      nil
    end
  end
end
