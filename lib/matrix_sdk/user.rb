require 'matrix_sdk/extensions'

module MatrixSdk
  class User
    attr_reader :id, :client, :display_name

    def initialize(client, id, data = {})
      @client = client
      @id = id

      @display_name = nil

      data.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end
    end
  end
end
