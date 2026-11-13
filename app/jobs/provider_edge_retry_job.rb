# Backoff wakes and recovery wakes for runs the model provider failed
# (ProviderEdgeRetry). "backoff" takes the failed run's id; "recovery" takes
# a completed run's id and looks for that resident's rooms to pick up.
class ProviderEdgeRetryJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: ->(id, kind) { "provider-edge-#{kind}-#{id}" }

  def perform(interaction_id, kind)
    run = AgentRuntimeInteraction.includes(:agent, :chat).find_by(id: interaction_id)
    return unless run

    case kind
    when "backoff"
      ProviderEdgeRetry.new(run).wake!(:backoff)
    when "recovery"
      return unless run.streak_outcome == :success && run.agent

      ProviderEdgeRetry.recover_for(run.agent, completed: run)
    end
  end

end
