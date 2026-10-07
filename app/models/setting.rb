class Setting < ApplicationRecord

  include Broadcastable

  has_one_attached :logo

  validates :max_accounts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :resident_turn_limit, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000 }
  validates :site_name, presence: true, length: { maximum: 100 }
  validates :safeguard_owner_notice_threshold,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :logo, content_type: [ :png, :jpg, :gif, :webp, :svg ],
                   size: { less_than: 5.megabytes },
                   if: -> { logo.attached? }

  broadcasts_to :all

  def account_creation_allowed?(user = Current.user)
    user&.is_site_admin? || Account.uncached { Account.count } < max_accounts
  end

  # Follow-through checks (FollowThroughCheck) are opt-in per resident:
  # "all", or a comma-separated list of resident ids (the id in their URL).
  # Empty: off for everyone.
  def follow_through_all?
    follow_through_residents.to_s.strip == "all"
  end

  def follow_through_resident_ids
    return [] if follow_through_all?
    follow_through_residents.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def follow_through_enabled_for?(agent)
    return false if agent.nil?
    follow_through_all? || follow_through_resident_ids.include?(agent.to_param)
  end

  def self.instance
    first_or_create!(site_name: ENV.fetch("SOULSHOUSE_SITE_NAME", "souls.house"))
  end

end
