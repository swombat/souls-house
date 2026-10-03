class MessageStoneRevision < ApplicationRecord

  belongs_to :message
  belongs_to :stone_revision

  validates :stone_revision_id, uniqueness: { scope: :message_id }
  validate :same_conversation
  validate :stone_is_available, on: :create

  private

  def same_conversation
    return unless message && stone_revision

    errors.add(:stone_revision, "must belong to the message's conversation") unless message.chat_id == stone_revision.stone.chat_id
  end

  def stone_is_available
    errors.add(:stone_revision, "has been withdrawn") if stone_revision&.stone&.withdrawn?
  end

end
