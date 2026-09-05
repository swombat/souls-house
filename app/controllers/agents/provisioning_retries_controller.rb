class Agents::ProvisioningRetriesController < ApplicationController

  include AgentScoped

  def create
    unless @agent.born_hosted? && @agent.provisioning?
      redirect_to onboarding_account_agent_path(current_account, @agent), alert: "This agent is not waiting for provisioning"
      return
    end

    @agent.update!(
      provisioning_started_at: Time.current,
      sandbox_last_error: nil,
      sandbox_last_error_at: nil,
      health_state: "unknown"
    )
    ProvisionAgentJob.perform_later(@agent.id)
    redirect_to onboarding_account_agent_path(current_account, @agent), notice: "Provisioning retry started"
  end

end
