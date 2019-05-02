module MatrixSdk::Protocols::IS
  def identity_status
    request(:get, :identity_api_v1, '/')
  end

  def identity_get_pubkey(id)
    id = ERB::Util.url_encode id.to_s

    request(:get, :identity_api_v1, "/pubkey/#{id}")
  end

  def identity_pubkey_isvalid(key, ephemeral: false)
    if ephemeral
      request(:get, :identity_api_v1, '/pubkey/ephemeral/isvalid', query: { public_key: key })
    else
      request(:get, :identity_api_v1, '/pubkey/isvalid', query: { public_key: key })
    end
  end

  def identity_pubkey_ephemeral_isvalid(key)
    identity_pubkey_isvalid(key, ephemeral: true)
  end

  def identity_lookup(medium:, address:)
    request(:get, :identity_api_v1, '/lookup', query: { medium: medium, address: address })
  end

  def identity_bulk_lookup(threepids)
    request(:post, :identity_api_v1, '/bulk_lookup', body: { threepids: threepids })
  end

  # XXX
end
