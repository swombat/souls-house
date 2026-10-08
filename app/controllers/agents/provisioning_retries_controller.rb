class Agents::ProvisioningRetriesController < ApplicationController

  include AgentScoped

  def create
    unless @agent.provisioning_retryable?
      redirect_to onboarding_account_agent_path(current_account, @agent), alert: "This resident is not waiting for provisioning"
      return
    end

    @agent.retry_provisioning!
    redirect_to onboarding_account_agent_path(current_account, @agent), notice: "Provisioning retry started"
  end

end
