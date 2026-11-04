class Agents::OnboardingController < ApplicationController

  include AgentScoped

  def show
    render inertia: "agents/onboarding", props: {
      agent: @agent.as_json,
      vm_steps: Agents::VmBirthProgress.for(@agent),
      first_conversation: Agents::FirstConversation.presentation(@agent),
      # The first resident in an account has no other residents to go back
      # to and nothing yet worth configuring, so the page offers neither.
      first_resident: current_account.agents.count == 1,
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
