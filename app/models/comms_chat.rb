# A chat on a comms (WhatsApp) ServiceConnection, written by the connector's
# signed events and read by residents with an enabled AgentServiceAccess.
class CommsChat < ApplicationRecord

  KINDS = %w[direct group broadcast].freeze

  belongs_to :service_connection
  has_many :comms_messages, dependent: :restrict_with_error

  encrypts :name

  validates :provider_chat_id, presence: true, uniqueness: { scope: :service_connection_id }
  validates :kind, inclusion: { in: KINDS }, allow_nil: true

  def public_id
    "chat_#{id}"
  end

  def as_comms_json
    {
      id: public_id,
      provider_chat_id: provider_chat_id,
      name: name,
      kind: kind,
      last_activity_at: last_activity_at&.utc&.iso8601
    }
  end

end
