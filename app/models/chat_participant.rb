# A human's durable place in a private conversation, recorded when they create
# it, or when it is made private later (the person who did it, and everyone who
# had written in it by then). It never depends on surviving messages; access
# still needs a confirmed membership of the account. (Posting can't add anyone:
# only a participant can post into a private chat, Message#author_is_in_private_chat.)
class ChatParticipant < ApplicationRecord

  SOURCES = %w[creator made_private writer].freeze

  belongs_to :chat
  belongs_to :user
  validates :source, inclusion: { in: SOURCES }

  def self.record!(chat:, user:, source:)
    return unless chat&.private? && user

    insert_all([ { chat_id: chat.id, user_id: user.id, source: source, created_at: Time.current } ],
      unique_by: %i[chat_id user_id])
  end

end
