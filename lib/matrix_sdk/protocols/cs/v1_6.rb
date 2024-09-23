# frozen_string_literal: true

module MatrixSdk::Protocols::CS::V1_6
  MatrixSdk::Protocols::CS.add_impl self, version: 'v1.6'

  def client_api_latest(path_frag)
    return :client_v1 if path_frag.size == 3 && path_frag.first == 'rooms' && path_frag.last == 'timestamp_to_event'

    super
  end
end
