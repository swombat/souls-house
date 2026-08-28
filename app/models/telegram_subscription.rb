class TelegramSubscription < ApplicationRecord

  include ObfuscatesId

  belongs_to :agent
  belongs_to :user
  has_many :telegram_messages, dependent: :destroy
  belongs_to :pending_safeguard_detection, class_name: "SafeguardDetection", optional: true

  scope :active, -> { where(blocked: false) }

  def subscriber_name
    user.full_name.presence || user.email_address
  end

  def mark_blocked!
    update!(blocked: true)
  end

  def request_runtime_reset!
    increment!(:runtime_session_generation)
  end

end
