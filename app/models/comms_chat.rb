# A chat on a comms (WhatsApp or Telegram) ServiceConnection, written by the
# connector's signed events and read by residents with an enabled
# AgentServiceAccess.
#
# provider_chat_id is the provider's own id; for Telegram it is a typed peer
# (user:<id>, chat:<id>, channel:<id>), and access hashes stay in the
# connector. sync_state says whether the chat is synced and, if not, why
# (broadcast_channel, large_group, bot, secret_chat), how far back its
# history goes (history_from), how fresh it is (synced_through, which only
# moves once Rails has the events it covers), whether forum topics are
# modelled, and how many deletions could not be applied.
class CommsChat < ApplicationRecord

  KINDS = %w[direct group broadcast saved supergroup channel bot].freeze
  SYNC_FIELDS = %w[synced reason history_from synced_through topics deletions_not_applied].freeze
  UNSYNCED_REASONS = %w[broadcast_channel large_group bot secret_chat].freeze

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
      last_activity_at: last_activity_at&.utc&.iso8601,
      sync_state: (sync_state.presence && sync_state.slice(*SYNC_FIELDS))
    }.compact
  end

end
