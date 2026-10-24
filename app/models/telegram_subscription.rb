class TelegramSubscription < ApplicationRecord

  include ObfuscatesId

  belongs_to :agent
  belongs_to :user
  has_many :telegram_messages, dependent: :destroy
  belongs_to :pending_safeguard_detection, class_name: "SafeguardDetection", optional: true

  scope :active, -> { where(blocked: false) }

  after_save :refresh_subscriber_count
  after_destroy -> { TelegramPresentation.refresh!(agent_id) }, if: -> { blocked == false }

  def subscriber_name
    user.full_name.presence || user.email_address
  end

  # Whether this subscriber may see a room's content. A resident can now act in
  # guest accounts, so its subscribers (members of its home account) are not
  # automatically members of the room's account.
  def reads_account?(account_id)
    user.confirmed_accounts.enabled.exists?(account_id)
  end

  def mark_blocked!
    update!(blocked: true)
  end

  def request_runtime_reset!
    increment!(:runtime_session_generation)
  end

  private

  def refresh_subscriber_count
    if previously_new_record?
      TelegramPresentation.refresh!(agent_id) if blocked == false
      return
    end
    return unless saved_change_to_blocked? || saved_change_to_agent_id?

    old_blocked = saved_change_to_blocked? ? blocked_before_last_save : blocked
    old_agent_id = saved_change_to_agent_id? ? agent_id_before_last_save : agent_id
    return if old_agent_id == agent_id && (old_blocked == false) == (blocked == false)

    ids = []
    ids << old_agent_id if old_blocked == false
    ids << agent_id if blocked == false
    TelegramPresentation.refresh!(ids)
  end

end
