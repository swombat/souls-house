class ExternalAgentWakeJob < ApplicationJob

  queue_as :default

  def perform
    now = Time.current

    wakeable_agents.select { |agent| agent.heartbeat_wake_due_at?(now) }.each do |agent|
      ExternalAgentWakeRequest.new(agent: agent).call
    end
  end

  private

  def wakeable_agents
    Agent.active
         .unpaused
         .not_billing_held
         .where(runtime: "external")
         .where(scheduled_wakes_enabled: true)
         .where.not(trigger_bearer_token: [ nil, "" ])
  end

end
