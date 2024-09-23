# frozen_string_literal: true

module MatrixSdk::Protocols::CS::V1_2
  MatrixSdk::Protocols::CS.add_impl self, version: 'v1.2'

  def client_api_latest(path_frag)
    return :client_v1 if path_frag == %w[register m.login.registration_token validity]
    return :client_v1 if path_frag.first == 'rooms' && path_frag[2] == 'hierarchy'

    super
  end
end
