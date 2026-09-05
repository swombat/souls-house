class Agents::OnboardingController < ApplicationController

  include AgentScoped

  def show
    render inertia: "agents/onboarding", props: {
      agent: @agent.as_json,
      account: current_account.as_json,
      provisioning_retry_url: account_agent_provisioning_retry_path(current_account, @agent),
      orientation_retry_url: account_agent_orientation_retry_path(current_account, @agent)
    }
  end

  private

  # Onboarding is a member route; nested resource controllers use :agent_id.
  def set_agent
    @agent = current_account.agents.find(params[:id])
  end

end
