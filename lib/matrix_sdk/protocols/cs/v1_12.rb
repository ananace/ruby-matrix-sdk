# frozen_string_literal: true

module MatrixSdk::Protocols::CS::V1_12
  MatrixSdk::Protocols::CS.add_impl self, version: 'v1.12'

  def join_room(id_or_alias, reason: nil, **params)
    query = {}
    query[:via] = params[:server_name] if params[:server_name]
    query[:via] = params[:via] if params[:via]
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {}
    content[:reason] = reason if reason

    id_or_alias = ERB::Util.url_encode id_or_alias.to_s

    request(:post, :client_latest, "/join/#{id_or_alias}", body: content, query: query)
  end

  def knock_room(id_or_alias, reason: nil, via: nil, **params)
    query = {}
    query[:via] = params[:server_name] if params[:server_name]
    query[:via] = via if via
    query[:user_id] = params.delete(:user_id) if protocol?(:AS) && params.key?(:user_id)

    content = {}
    content[:reason] = reason if reason

    id_or_alias = ERB::Util.url_encode id_or_alias.to_s

    request(:post, :client_latest, "/knock/#{id_or_alias}", body: content, query: query)
  end
end
