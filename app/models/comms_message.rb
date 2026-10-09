# One message in a CommsChat. Media are not downloaded in milestone 1:
# media_kind records what it was ("image", "voice_note", ...) and the caption
# is kept.
class CommsMessage < ApplicationRecord

  belongs_to :service_connection
  belongs_to :comms_chat
  # Attribution, not body: set when the echo and the send acknowledgement
  # meet, whichever arrives second. The body is never rewritten.
  belongs_to :comms_send, optional: true

  encrypts :sender_id, :sender_name, :body, :caption

  validates :provider_message_id, presence: true, uniqueness: { scope: :service_connection_id }
  validates :sent_at, presence: true
  validate :chat_on_same_connection

  def as_comms_json
    {
      provider_message_id: provider_message_id,
      chat: comms_chat.provider_chat_id,
      sender_id: sender_id,
      sender_name: sender_name,
      sent_at: sent_at.utc.iso8601,
      body: body,
      media_kind: media_kind,
      caption: caption,
      from_me: from_me,
      sent_by: comms_send && { resident_id: comms_send.agent.to_param, resident_name: comms_send.agent.name, send_id: comms_send.public_id }
    }
  end

  private

  def chat_on_same_connection
    return unless comms_chat && service_connection_id
    errors.add(:comms_chat, "must belong to the same connection") unless comms_chat.service_connection_id == service_connection_id
  end

end
