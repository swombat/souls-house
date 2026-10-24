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

  # Capture each count change before a later save/touch replaces saved_changes.
  # IntegrationStatus delivers only after the outermost transaction commits.
  after_save :refresh_integration_status, if: :summary_counts_changed?
  after_destroy :refresh_integration_status

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

  private

  def summary_counts_changed?
    previously_new_record? || saved_change_to_service_connection_id? || synced_membership_changed?
  end

  def synced_membership_changed?
    return false unless saved_change_to_sync_state?

    states = saved_change_to_sync_state
    return false if states.map { |state| state.is_a?(Hash) ? state["synced"] : nil }.uniq.size == 1

    # Match ServiceConnection#comms_summary exactly, including missing/null
    # and PostgreSQL's boolean spellings. Ruby truthiness is not this predicate.
    # Do not add validation to existing writes: malformed values already have
    # an undefined summary, so conservatively refresh when they change.
    # Materialization keeps the planner from casting constants before CASE.
    sql = <<~SQL
      WITH states AS MATERIALIZED (
        SELECT ?::jsonb->>'synced' AS old_value, ?::jsonb->>'synced' AS new_value
      )
      SELECT CASE
        WHEN pg_input_is_valid(old_value, 'boolean') IS FALSE
          OR pg_input_is_valid(new_value, 'boolean') IS FALSE THEN TRUE
        ELSE (old_value::boolean IS NOT FALSE) <> (new_value::boolean IS NOT FALSE)
      END
      FROM states
    SQL
    self.class.connection.select_value(self.class.sanitize_sql_array([ sql, *states.map(&:to_json) ]))
  end

  def refresh_integration_status
    connection_ids = [ service_connection_id ]
    connection_ids.concat(saved_change_to_service_connection_id.to_a) unless destroyed?
    IntegrationStatus.refresh!(ServiceConnection.where(id: connection_ids.compact).pluck(:account_id))
  end

end
