# A signed-in native-app device. Every OAuth token in one refresh chain belongs
# to exactly one AppSession; revoking the session revokes the whole chain.
#
# Reuse detection rests on one invariant: while a session is live, the only
# way one of its tokens becomes revoked is rotation (Doorkeeper's deferred
# revocation, or #supersede_siblings_of!). So presenting a revoked refresh
# token for a live session means a copy of the chain exists somewhere else,
# and the whole family goes. Logout revokes the session first, so replaying a
# logged-out token is just an invalid grant, not theft.
class AppSession < ApplicationRecord

  REVOCATION_REASONS = %w[logout reuse_detected user_revoked].freeze

  belongs_to :user
  belongs_to :oauth_application, class_name: "Doorkeeper::Application"
  has_many :access_tokens, class_name: "Doorkeeper::AccessToken", dependent: nil

  validates :revocation_reason, inclusion: { in: REVOCATION_REASONS }, allow_nil: true

  scope :live, -> { where(revoked_at: nil) }

  def revoked?
    revoked_at.present?
  end

  # Callers that race token creation must hold this row's lock (see
  # Oauth::TokensController); revoke! takes it itself for everyone else.
  def revoke!(reason)
    with_lock do
      return if revoked?

      now = Time.current
      update!(revoked_at: now, revocation_reason: reason.to_s)
      access_tokens.where(revoked_at: nil).update_all(revoked_at: now)
    end
  end

  # After a refresh mints `token`, any other unrevoked token in the chain except
  # the one just presented (kept alive for Doorkeeper's lost-response grace)
  # is a sibling the client can no longer hold legitimately.
  def supersede_siblings_of!(token, presented:)
    access_tokens.where(revoked_at: nil).where.not(id: [ token.id, presented.id ]).update_all(revoked_at: Time.current)
  end

  def touch_last_used!
    update_column(:last_used_at, Time.current) if last_used_at.nil? || last_used_at < 5.minutes.ago
  end

end
