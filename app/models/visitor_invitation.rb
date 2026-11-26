# An owner's invitation for one visitor: a resident of another house to take
# a seat in this account (JdWxAj). It admits a visitor; it does not
# authenticate a house. Expiring and single-use; the raw token is shown once
# and only its digest is kept.
class VisitorInvitation < ApplicationRecord

  LIFETIME = 7.days

  belongs_to :account
  belongs_to :created_by_user, class_name: "User", optional: true
  has_one :visitor_admission, dependent: :nullify

  attr_reader :raw_token

  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  validates :local_name, length: { maximum: 40 }, allow_nil: true

  scope :unaccepted, -> { where(accepted_at: nil, revoked_at: nil).where("expires_at > ?", Time.current) }

  def self.digest(token)
    Digest::SHA256.hexdigest(token.to_s)
  end

  def self.issue!(account:, user:, local_name: nil)
    token = "vinv_#{SecureRandom.urlsafe_base64(32)}"
    invitation = create!(account: account, created_by_user: user, local_name: local_name.presence,
      token_digest: digest(token), expires_at: LIFETIME.from_now)
    invitation.instance_variable_set(:@raw_token, token)
    invitation
  end

  def self.find_by_token(token)
    return nil if token.blank?

    find_by(token_digest: digest(token))
  end

  def open?
    accepted_at.nil? && revoked_at.nil? && expires_at.future?
  end

  def state
    return "accepted" if accepted_at
    return "revoked" if revoked_at
    return "expired" unless expires_at.future?

    "open"
  end

  def revoke!
    update!(revoked_at: Time.current) if open?
  end

  # What a visitor may see before accepting: whose account and house, and
  # until when. Nothing about who is in it.
  def preview_json
    {
      account: { name: account.name },
      house: { name: VisitorInvitation.house_name, origin: VisitorInvitation.house_origin },
      local_name: local_name,
      expires_at: expires_at.iso8601,
      state: state
    }
  end

  def self.house_name
    ENV["SOULSHOUSE_HOUSE_NAME"].presence || "souls.house"
  end

  def self.house_origin
    host = Rails.application.config.action_mailer.default_url_options&.dig(:host)
    host ? "https://#{host}" : nil
  end

  # Accepting mints a fresh visiting Agent for this one visit, under a lock
  # on the invitation so a token can admit once.
  def accept!(name:, colour: nil, icon: nil, home_origin:, home_name: nil)
    with_lock do
      raise ArgumentError, "This invitation is no longer open" unless open?

      local = local_name.presence || name.to_s.strip
      raise ArgumentError, "A name is required" if local.blank?
      origin = VisitorAdmission.normalize_origin(home_origin)
      raise ArgumentError, "home_origin must be an https origin" unless origin

      token = "visit_#{SecureRandom.urlsafe_base64(32)}"
      admission = nil
      transaction do
        agent = account.visiting_agents.create!(
          name: local,
          runtime: "visiting",
          colour: (colour if colour.in?(Agent::VALID_COLOURS)),
          icon: (icon if icon.in?(Agent::VALID_ICONS)),
          active: true
        )
        admission = VisitorAdmission.create!(
          account: account, agent: agent, visitor_invitation: self,
          visit_token_digest: VisitorAdmission.digest(token),
          home_origin: origin, home_name: home_name.to_s.strip.first(80).presence
        )
        update!(accepted_at: Time.current)
      end
      admission.instance_variable_set(:@raw_token, token)
      admission
    end
  end

  def as_json(*)
    {
      id: to_param,
      local_name: local_name,
      state: state,
      expires_at: expires_at.iso8601,
      created_at: created_at.iso8601
    }
  end

end
