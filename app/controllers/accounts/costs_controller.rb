class Accounts::CostsController < ApplicationController

  require_feature_enabled :agents

  def show
    render inertia: "accounts/costs", props: {
      account: current_account.as_json,
      agents: -> { cost_agents },
      cost_report: -> { AccountInteractionCostReport.new(account: current_account).call }
    }
  end

  private

  def cost_agents
    current_account.agents.map { |agent| { id: agent.to_param } }
  end

end
