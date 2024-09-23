# frozen_string_literal: true

module MatrixSdk::Protocols::CS::V1_7
  MatrixSdk::Protocols::CS.add_impl self, version: 'v1.7'

  def client_api_latest(path_frag)
    return :client_v1 if path_frag == %w[login get_token]

    super
  end

  def media_api_latest(path_frag)
    return :media_v1 if path_frag.first == 'create'

    super
  end
end
