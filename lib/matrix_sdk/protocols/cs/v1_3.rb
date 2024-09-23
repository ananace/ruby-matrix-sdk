# frozen_string_literal: true

module MatrixSdk::Protocols::CS::V1_3
  MatrixSdk::Protocols::CS.add_impl self, version: 'v1.3'

  def client_api_latest(path_frag)
    return :client_v1 if path_frag.first == 'rooms' && path_frag[2] == 'relations'

    super
  end
end
