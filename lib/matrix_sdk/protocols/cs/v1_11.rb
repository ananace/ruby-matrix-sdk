# frozen_string_literal: true

module MatrixSdk::Protocols::CS::V1_11
  MatrixSdk::Protocols::CS.add_impl self, version: 'v1.11'

  def client_api_latest(path_frag)
    return :client_v1 if path_frag.first == 'media'

    super
  end

  def media_api_latest(path_frag)
    return :client_v1_media if \
      %w[config download preview_url thumbnail].include? path_frag.first

    super
  end
end
