# One message in a CommsChat. Media are not downloaded in milestone 1:
# media_kind records what it was ("image", "voice_note", ...) and the caption
# is kept.
#
# A provider message id is unique within its chat, not its connection:
# Telegram numbers channel and supergroup messages per peer. An edit replaces
# body and caption (edit_version orders edits). A deletion keeps the row as
# a tombstone with the content blanked; nothing brings the content back.
class CommsMessage < ApplicationRecord

  belongs_to :service_connection
  belongs_to :comms_chat

  encrypts :sender_id, :sender_name, :body, :caption

  validates :provider_message_id, presence: true, uniqueness: { scope: :comms_chat_id }
  validates :sent_at, presence: true
  validate :chat_on_same_connection

  def deleted?
    deleted_at.present?
  end

  def tombstone!(at:)
    return if deleted?

    update!(deleted_at: at, body: nil, caption: nil)
  end

  def as_comms_json
    json = {
      provider_message_id: provider_message_id,
      chat: comms_chat.provider_chat_id,
      sender_id: sender_id,
      sender_name: sender_name,
      sent_at: sent_at.utc.iso8601,
      body: body,
      media_kind: media_kind,
      caption: caption
    }
    json[:edited_at] = edited_at.utc.iso8601 if edited_at
    json[:deleted] = true if deleted?
    json
  end

  private

  def chat_on_same_connection
    return unless comms_chat && service_connection_id
    errors.add(:comms_chat, "must belong to the same connection") unless comms_chat.service_connection_id == service_connection_id
  end

end
