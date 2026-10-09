# One grant or withdrawal of a resident's permission to send through a comms
# connection as its owner (spec §5): who, when, which resident, and why. The
# owner's connection page lists them. actor_user is nil when the house
# withdrew the grant itself (disconnect, re-pair, owner change).
class CommsSendGrantEvent < ApplicationRecord

  ACTIONS = %w[granted withdrawn].freeze
  REASONS = (%w[granted] + AgentServiceAccess::SEND_WITHDRAWAL_REASONS).freeze

  belongs_to :service_connection
  belongs_to :agent
  belongs_to :actor_user, class_name: "User", optional: true

  validates :action, inclusion: { in: ACTIONS }
  validates :reason, inclusion: { in: REASONS }

  def self.record!(access, granted:, actor:, reason:)
    create!(
      service_connection_id: access.service_connection_id,
      agent_id: access.agent_id,
      actor_user: actor,
      action: granted ? "granted" : "withdrawn",
      reason: reason,
      created_at: Time.current
    )
  end

  def as_owner_json
    {
      resident_id: agent.to_param,
      resident_name: agent.name,
      action: action,
      reason: reason,
      actor_user_id: actor_user_id,
      actor_name: actor_user&.display_name,
      at: created_at.utc.iso8601
    }
  end

end
