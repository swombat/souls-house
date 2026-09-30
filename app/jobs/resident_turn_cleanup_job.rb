class ResidentTurnCleanupJob < ApplicationJob

  queue_as :default
  discard_on ActiveRecord::RecordNotFound

  def perform(agent_id)
    return unless Agents::Config.cold_start?
    agent = Agent.find(agent_id)
    Agents::Sandbox.new(agent).stop_if_idle!
  end

end
