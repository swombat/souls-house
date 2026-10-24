class CompanionCableTicket < ApplicationRecord

  LIFETIME = 60.seconds
  PROTOCOL_PREFIX = "souls-house.companion.".freeze

  belongs_to :companion_device

  def self.issue!(device)
    value = "shct_#{SecureRandom.urlsafe_base64(32)}"
    ticket = create!(companion_device: device, token_digest: Digest::SHA256.hexdigest(value),
      grant_revision: device.grant_revision, expires_at: LIFETIME.from_now)
    [ value, ticket ]
  end

  def self.redeem(value)
    return unless value.is_a?(String) && value.match?(/\Ashct_[A-Za-z0-9_-]{43}\z/)

    ticket = find_by(token_digest: Digest::SHA256.hexdigest(value))
    return unless ticket

    # Device first everywhere (session issuance and revocation included), to
    # avoid deadlocks and make redemption take turns with revocation.
    device = ticket.companion_device
    device.with_lock do
      ticket.lock!
      return unless device.active? && ticket.consumed_at.nil? && ticket.expires_at > Time.current &&
        ticket.grant_revision == device.grant_revision

      ticket.update!(consumed_at: Time.current)
      device
    end
  end

end
