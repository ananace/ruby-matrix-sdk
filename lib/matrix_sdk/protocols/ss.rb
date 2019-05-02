module MatrixSdk::Protocols::SS
  # Gets the server version
  def server_version
    Response.new(self, request(:get, :federation_v1, '/version').server).tap do |resp|
      resp.instance_eval <<-'CODE', __FILE__, __LINE__ + 1
        def to_s
          "#{name} #{version}"
        end
      CODE
    end
  end
end
