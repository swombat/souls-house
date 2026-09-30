class Setting < ApplicationRecord

  include Broadcastable

  has_one_attached :logo

  validates :max_accounts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
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

  def self.instance
    first_or_create!(site_name: ENV.fetch("SOULSHOUSE_SITE_NAME", "souls.house"))
  end

end
