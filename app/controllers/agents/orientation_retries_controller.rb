class Agents::OrientationRetriesController < ApplicationController

  include AgentScoped

  def create
    unless @agent.orientation_retryable?
      redirect_to onboarding_account_agent_path(current_account, @agent), alert: "The runtime must be healthy before orientation"
      return
    end

    @agent.retry_orientation!
    redirect_to onboarding_account_agent_path(current_account, @agent), notice: "Another orientation wake has been queued"
  end

end
