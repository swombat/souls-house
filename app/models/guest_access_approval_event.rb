# One transition of a guest integration grant (JWblqj): the sharing house
# asked, the home approved, declined or revoked, the sharing side withdrew,
# the request expired, or the guest left. Who, when, which request
# (generation) and why. actor_user is nil when the house moved it itself
# (expiry, an authority change on the connection, the guest leaving).
class GuestAccessApprovalEvent < ApplicationRecord

  ACTIONS = %w[requested approved declined revoked withdrawn expired guest_left].freeze
  # requested: by the sharing side (requested), after a send grant widened it
  # (send_granted), or because the connection's owner, identity or authority
  # changed under an approval (authority_changed).
  # withdrawn: the sharing side switched it off while approved
  # (access_disabled) or while still pending (request_withdrawn).
  REASONS = %w[requested send_granted authority_changed access_disabled request_withdrawn].freeze

  belongs_to :service_connection
  belongs_to :agent
  belongs_to :actor_user, class_name: "User", optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :reason, inclusion: { in: REASONS }, allow_nil: true

  def self.record!(access, action:, actor:, reason: nil)
    create!(
      service_connection_id: access.service_connection_id,
      agent_id: access.agent_id,
      actor_user: actor,
      action: action,
      reason: reason,
      generation: access.home_approval_generation,
      created_at: Time.current
    )
  end

  def as_json(*)
    {
      action: action,
      reason: reason,
      generation: generation,
      actor_name: actor_user&.display_name,
      at: created_at.utc.iso8601
    }
  end

end
