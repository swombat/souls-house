# Defense in depth for Disk storage: even an internally minted service URL
# cannot turn a stone's HTML into an unsandboxed, independently cached response.
module HidesStoneDiskFiles

  private

  def decode_verified_key
    key = super
    return unless key
    return if ActiveStorage::Blob.where(key: key[:key])
      .where("metadata::jsonb ->> 'stone_html' = 'true'").exists?

    key
  end

end
