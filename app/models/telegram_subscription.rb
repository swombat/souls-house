class TelegramSubscription < ApplicationRecord

  include ObfuscatesId

  CHAT_KINDS = %w[direct group].freeze
  GROUP_CHAT_TYPES = %w[group supergroup].freeze

  belongs_to :agent
  # A direct thread belongs to the person who subscribed; a group thread
  # belongs to nobody but the group, and the database holds that line
  # (telegram_subscriptions_kind_user).
  belongs_to :user, optional: true
  belongs_to :allowed_by, class_name: "User", optional: true
  has_many :telegram_messages, dependent: :destroy
  belongs_to :pending_safeguard_detection, class_name: "SafeguardDetection", optional: true

  validates :chat_kind, inclusion: { in: CHAT_KINDS }
  validates :user, presence: true, if: :direct?

  scope :direct, -> { where(chat_kind: "direct") }
  scope :groups, -> { where(chat_kind: "group") }
  # Threads the resident may be woken for and may send into: a direct
  # subscriber who hasn't blocked the bot, or a group the owner has allowed
  # that the bot is still in. Checked again before every send.
  scope :active, -> {
    where(blocked: false).where(
      "telegram_subscriptions.chat_kind = 'direct' OR " \
      "(telegram_subscriptions.allowed = TRUE AND telegram_subscriptions.removed_at IS NULL)"
    )
  }

  after_save :refresh_subscriber_count
  after_commit -> { TelegramPresentation.refresh!(agent_id) }, if: :group?
  after_destroy -> { TelegramPresentation.refresh!(agent_id) }, if: -> { blocked == false }

  def direct?
    chat_kind == "direct"
  end

  def group?
    chat_kind == "group"
  end

  def subscriber_name
    return title.presence || "Telegram group" if group?

    user.full_name.presence || user.email_address
  end

  # A group thread can be woken for, and sent into, only while it is allowed
  # and the bot is still a member. Read from the database, not this instance,
  # so a revocation made after the caller loaded the row still wins.
  def deliverable?
    self.class.active.exists?(id)
  end

  def allow!(by:)
    raise ArgumentError, "only a group can be allowed" unless group?

    update!(allowed: true, allowed_at: Time.current, allowed_by: by)
  end

  def disallow!
    raise ArgumentError, "only a group can be allowed" unless group?

    update!(allowed: false)
  end

  # Whether this subscriber may see a room's content. A resident can now act in
  # guest accounts, so its subscribers (members of its home account) are not
  # automatically members of the room's account.
  def reads_account?(account_id)
    return false if group?

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
