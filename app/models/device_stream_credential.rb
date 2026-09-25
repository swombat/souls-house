class DeviceStreamCredential < ApplicationRecord

  belongs_to :device_stream

  def self.authenticate(token)
    return unless token.is_a?(String) && token.match?(/\Ashd_[0-9a-f]{64}\z/)
    find_by(token_digest: Digest::SHA256.hexdigest(token), revoked_at: nil)
  end

end
