class ReplyExpectation < ApplicationRecord

  DIRECT_MENTION_VERSION = "direct-mention-v1"

  belongs_to :message
  belongs_to :user
  belongs_to :answered_by_message, class_name: "Message", optional: true

  enum :state, { open: 0, answered: 1, dismissed: 2 }, prefix: true
  validates :score, numericality: { in: 0..1 }
  validates :classifier_version, presence: true

  scope :visible_to, ->(user) {
    joins(message: :chat).where(user: user, messages: { discarded_at: nil },
      chats: { discarded_at: nil, account_id: user.confirmed_accounts.select(:id) })
  }

  after_commit -> { self.class.refresh_for(user_id) }

  def self.summary_for(user, account:)
    counts = visible_to(user).state_open.group("chats.account_id", "chats.id")
      .pluck("chats.account_id", "chats.id", Arel.sql("COUNT(*)"), Arel.sql("MAX(messages.id)"))
    accounts = Account.where(id: counts.map(&:first)).index_by(&:id)
    chats = Chat.where(id: counts.filter_map { |aid, cid| cid if aid == account&.id }).index_by(&:id)
    by_account = Hash.new(0)
    by_chat = {}
    through_messages = {}
    counts.each do |aid, cid, count, through_id|
      by_account[accounts.fetch(aid).to_param] += 1
      next unless chats.key?(cid)
      by_chat[chats.fetch(cid).to_param] = count
      through_messages[chats.fetch(cid).to_param] = Message.encode_id(through_id)
    end
    { total: counts.size, accounts: by_account, chats: by_chat, through_messages: through_messages }
  end

  # Call only while holding the chat's write lock. All inference paths use this
  # same guard, including late results, retries and message edits.
  def self.record!(message:, user:, score:, classifier_version: ReplyExpectationClassifier::VERSION)
    return unless user.confirmed_accounts.exists?(id: message.chat.account_id)
    expectation = find_or_initialize_by(message: message, user: user)
    return expectation if expectation.persisted? && !expectation.state_open?

    cutoff = ReplyDismissal.find_by(chat_id: message.chat_id, user: user)&.through_message_id
    reply = message.chat.messages.kept.where(user: user, role: "user")
      .where("messages.id > ?", message.id).order(:id).first
    expectation.assign_attributes(score: score, classifier_version: classifier_version)
    if cutoff && message.id <= cutoff
      expectation.state = :dismissed
    elsif reply
      expectation.state = :answered
      expectation.answered_by_message = reply
    else
      expectation.state = :open
    end
    expectation.save!
    expectation
  end

  def self.close_for_reply!(message)
    return unless message.user_id && message.role == "user"
    # Message::Revisioned has already acquired this chat row's lock in the
    # enclosing message transaction, serialising with classification/dismissal.
    joins(:message).state_open.where(user_id: message.user_id, messages: { chat_id: message.chat_id })
      .where("messages.id < ?", message.id).find_each do |expectation|
        expectation.update!(state: :answered, answered_by_message: message)
      end
  end

  def self.refresh_for(user_id)
    user = User.find_by(id: user_id)
    return unless user
    ActionCable.server.broadcast("ReplyAttention:#{user.to_param}", { action: "refresh" })
  rescue StandardError => error
    Rails.logger.warn("Reply attention refresh failed: #{error.class}")
  end

end
