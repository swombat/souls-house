# Bringing a resident from one of your other accounts into this one as a guest,
# and ending that arrangement from either side.
class Accounts::GuestMembershipsController < ApplicationController

  require_feature_enabled :agents

  def create
    agent = GuestMembership.candidates_for(account: current_account, user: Current.user)
      .find(params.require(:agent_id))
    membership = current_account.guest_memberships.create!(agent: agent, added_by: Current.user)
    audit("add_guest_resident", membership, agent_id: agent.id, home_account_id: agent.account_id)
    redirect_to account_agents_path(current_account), notice: "#{agent.name} is now a guest here"
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
    redirect_to account_agents_path(current_account), alert: "That resident can't be added as a guest here"
  end

  # The receiving account removes its guest, or the hosting account withdraws
  # its resident. Either side is enough.
  def destroy
    membership = GuestMembership
      .where(account: current_account)
      .or(GuestMembership.where(agent_id: current_account.agents.select(:id)))
      .find(params[:id])
    return deny_account_access!("You don't have permission to change this guest") unless membership.removable_by?(Current.user)

    membership.destroy!
    audit("remove_guest_resident", membership, agent_id: membership.agent_id, account_id: membership.account_id)
    redirect_to account_agents_path(current_account), notice: "#{membership.agent.name} is no longer a guest in #{membership.account.name}"
  end

end
