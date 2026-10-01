class ReplyDismissal < ApplicationRecord

  belongs_to :chat
  belongs_to :user
  validates :through_message_id, numericality: { only_integer: true, greater_than: 0 }

  def self.dismiss!(chat:, user:, through:)
    raise ArgumentError, "Cutoff belongs to another conversation" unless through.chat_id == chat.id
    chat.with_lock do
      dismissal = find_or_initialize_by(chat: chat, user: user)
      dismissal.through_message_id = [ dismissal.through_message_id.to_i, through.id ].max
      dismissal.save!
      ReplyExpectation.joins(:message).state_open.where(user: user, messages: { chat_id: chat.id })
        .where("messages.id <= ?", dismissal.through_message_id).find_each do |expectation|
          expectation.update!(state: :dismissed)
        end
    end
  end

end
