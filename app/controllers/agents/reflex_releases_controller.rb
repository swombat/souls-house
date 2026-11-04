# Releases one held reflex (an account import brings reflexes in held). Only
# a person who owns the account can do this; starting the resident does not.
class Agents::ReflexReleasesController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_owner!

  def create
    agent = current_account.agents.find(params[:agent_id])
    reflex = agent.reflexes.kept.find(params[:reflex_id])
    if reflex.held?
      reflex.release!
      AuditLog.create!(user: Current.user, account: current_account, action: "release_imported_reflex", auditable: agent,
        data: { "reflex_id" => reflex.id })
    end
    redirect_to edit_account_agent_path(current_account, agent, tab: "reflexes"), status: :see_other, notice: "Reflex released."
  end

end
