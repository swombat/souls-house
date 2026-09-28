module AgentRuntimeInteraction::ResponseChain

  extend ActiveSupport::Concern

  included do
    after_update_commit :advance_response_chain!, if: :finished_at?
  end

  # A committed, explicitly linked reply is enough for the next *resident* to
  # read it. It is NOT proof that this resident stopped executing. Never clear
  # finished_at, execution_state, the activity lease, or the runtime's turn lock.
  def advance_response_chain!
    return unless response_chain_ready?

    AllAgentsResponseJob.perform_later(chat, response_chain_agent_ids, after_interaction_id: id)
  end

  def response_chain_ready?
    return false if response_chain_agent_ids.empty? || response_chain_advanced_at?
    return false unless chat&.respondable? && chat.manual_responses?
    # A cancelled or expired request never advances, whatever its runs did.
    return false if message_dispatch && !message_dispatch.reload.reserved?
    # Nor does a run of it that never started: a cancellation (its deadline
    # passed unclaimed, or its claim was refused) is not a turn taken.
    return false if message_dispatch && execution_state == "cancelled"

    posted = linked_messages.where(role: "assistant", agent_id: agent_id, chat_id: chat_id).exists?
    return true if posted
    finished_at? && error_class.blank? && !execution_state.in?(%w[busy outcome_unknown]) && !transport_status.in?([ 0, 409 ])
  end

end
