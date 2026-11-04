class Notice < ApplicationRecord

  SCOPES = %w[system account].freeze
  TYPES = %w[model_changed site_renamed announcement].freeze
  # How long a posted announcement stays up, in days. Anything else falls
  # back to the default.
  EXPIRY_DAYS = [ 1, 3, 7, 14, 30 ].freeze
  DEFAULT_EXPIRY_DAYS = 7

  belongs_to :account, optional: true
  belongs_to :created_by, class_name: "User", optional: true
  # Set when a resident posted it (POST /api/v1/announcements); a person's
  # notices keep created_by instead.
  belongs_to :created_by_agent, class_name: "Agent", optional: true

  validates :scope, inclusion: { in: SCOPES }
  validates :notice_type, inclusion: { in: TYPES }
  validates :expires_at, presence: true
  validates :body, presence: true, length: { maximum: 5_000 }, if: -> { notice_type == "announcement" }
  validate :account_matches_scope

  scope :active, -> { where("expires_at > ?", Time.current) }
  scope :announcements, -> { where(notice_type: "announcement") }

  def self.expiry_days_for(requested)
    requested = requested.to_i
    EXPIRY_DAYS.include?(requested) ? requested : DEFAULT_EXPIRY_DAYS
  end

  # A standing announcement to every resident in the account, as posted from
  # the account's notices page or through the API.
  def self.announce_to_account!(account:, body:, expires_in_days:, created_by: nil, created_by_agent: nil)
    account.notices.create!(
      scope: "account",
      notice_type: "announcement",
      body: body,
      expires_at: expiry_days_for(expires_in_days).days.from_now,
      created_by: created_by,
      created_by_agent: created_by_agent
    )
  end

  # A standing announcement to every resident on the site. Site admins post
  # these from Admin → Notices; a resident only once a site admin has switched
  # it on (Agent#can_post_site_announcements).
  def self.announce_to_site!(body:, expires_in_days:, created_by: nil, created_by_agent: nil)
    create!(
      scope: "system",
      notice_type: "announcement",
      body: body,
      expires_at: expiry_days_for(expires_in_days).days.from_now,
      created_by: created_by,
      created_by_agent: created_by_agent
    )
  end

  # Ending an announcement keeps the row; it simply stops being active.
  def expire!
    update!(expires_at: Time.current)
  end

  def self.for_agent(agent)
    active.where(
      "scope = :system OR (scope = :account AND account_id = :account_id)",
      system: "system",
      account: "account",
      account_id: agent.account_id
    ).includes(:created_by_agent).order(:created_at, :id)
  end

  def as_management_json
    {
      id: id,
      body: body,
      scope: scope,
      created_at: created_at.iso8601,
      expires_at: expires_at.iso8601,
      created_by: created_by&.email_address || created_by_agent&.name,
      created_by_resident: created_by_agent && { id: created_by_agent.to_param, name: created_by_agent.name }
    }
  end

  private

  def account_matches_scope
    if scope == "system" && account_id.present?
      errors.add(:account, "must be absent for system notices")
    elsif scope == "account" && account_id.blank?
      errors.add(:account, "must be present for account notices")
    end
  end

end
