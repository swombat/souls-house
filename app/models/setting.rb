class Setting < ApplicationRecord

  include Broadcastable

  FOLLOW_THROUGH_SCOPES = %w[off selected all].freeze

  has_one_attached :logo

  # Field OCR covers only files brought in after it was (last) turned on.
  before_save { self.field_ocr_enabled_at = Time.current if field_ocr_enabled_changed?(to: true) }

  validates :max_accounts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :resident_turn_limit, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000 }
  validates :field_ocr_daily_usd_ceiling, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
  validates :vm_resident_limit, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000 }
  validates :follow_through_scope, inclusion: { in: FOLLOW_THROUGH_SCOPES }
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

  # Follow-through checks (FollowThroughCheck) are opt-in: off, on for the
  # residents an admin has picked (agents.follow_through), or on for all.
  def follow_through_enabled_for?(agent)
    return false if agent.nil?
    case follow_through_scope
    when "all" then true
    when "selected" then agent.follow_through?
    else false
    end
  end

  def self.instance
    first_or_create!(site_name: ENV.fetch("SOULSHOUSE_SITE_NAME", "souls.house"))
  end

end
