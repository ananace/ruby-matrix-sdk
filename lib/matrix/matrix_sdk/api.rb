require 'net/http'
require 'uri'

module MatrixSdk
  class Api
    attr_accessor :homeserver

    def initialize(homeserver, username, password, params = {})
      @homeserver = homeserver
      @username = username
      @password = password
    end

    def api_versions
      request('/client/versions')
    end

    def valid?

    end

    private

    def baseurl
      URI("https://#{username}:#{password}@#{homeserver}/_matrix")
    end

    def request(req)
      
    end
  end
end
