# One message a resident asked to send through a comms (WhatsApp) connection,
# as the connection's owner (spec §5). The row is written before the
# connector is called, so a send that happened always has a record.
#
#   pending  claimed, not yet handed to the connector
#   unknown  handed to the connector with no definite outcome (a timeout,
#            a lost connection, a restart); never retried automatically
#   sent     the connector reports WhatsApp accepted it (not delivered/read)
#   failed   the connector reports it was not sent, or the house refused it
#            at dispatch before the connector was called
#
# provider_message_id is chosen here at claim time and handed to the
# connector, which uses it as the WhatsApp message ID. So the echo of the
# message (comms_messages, from_me) links to this record even when it
# arrives before the connector's acknowledgement.
class CommsSend < ApplicationRecord

  STATUSES = %w[pending sent failed unknown].freeze
  MAX_TEXT_LENGTH = 4096
  CLIENT_REQUEST_ID_FORMAT = /\A[A-Za-z0-9._:-]{1,100}\z/

  belongs_to :service_connection
  belongs_to :agent
  belongs_to :comms_chat
  has_one :comms_message, dependent: :nullify

  encrypts :text

  validates :text, presence: true, length: { maximum: MAX_TEXT_LENGTH }
  validates :client_request_id, format: { with: CLIENT_REQUEST_ID_FORMAT }
  validates :status, inclusion: { in: STATUSES }
  validates :requested_at, presence: true
  validate :chat_on_same_connection

  def public_id
    "send_#{id}"
  end

  # The WhatsApp message ID this send will use: derived from the send's own
  # ID and connection, in WhatsApp's web-client shape ("3EB0" + upper hex).
  def self.provider_message_id_for(connection_id, send_id)
    "3EB0#{Digest::SHA256.hexdigest("souls-house-comms-send:#{connection_id}:#{send_id}").first(20).upcase}"
  end

  def same_request?(chat, text)
    comms_chat_id == chat.id && self.text == text
  end

  # What the resident who sent it sees.
  def as_comms_json
    {
      id: public_id,
      client_request_id: client_request_id,
      chat: comms_chat.provider_chat_id,
      status: status,
      provider_message_id: provider_message_id,
      error_code: error_code,
      requested_at: requested_at.utc.iso8601,
      sent_at: sent_at&.utc&.iso8601
    }
  end

  # What the connection's owner sees: who said what, to whom, when.
  def as_owner_json
    as_comms_json.merge(
      resident_id: agent.to_param,
      resident_name: agent.name,
      chat_name: comms_chat.name,
      text: text
    )
  end

  private

  def chat_on_same_connection
    return unless comms_chat && service_connection_id
    errors.add(:comms_chat, "must belong to the same connection") unless comms_chat.service_connection_id == service_connection_id
  end

end
