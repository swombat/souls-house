# Bringing a resident from one of your other accounts into this one as a guest,
# choosing whether new conversations invite them automatically, and ending that
# arrangement from either side.
class Accounts::GuestMembershipsController < ApplicationController

  require_feature_enabled :agents
  before_action :require_account_manager!, only: :update

  def create
    agent = GuestMembership.candidates_for(account: current_account, user: Current.user)
      .find(params.require(:agent_id))
    membership = current_account.guest_memberships.create!(agent: agent, added_by: Current.user)
    audit("add_guest_resident", membership, agent_id: agent.id, home_account_id: agent.account_id)
    redirect_to account_agents_path(current_account), notice: "#{agent.name} is now a guest here"
  rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
    redirect_to account_agents_path(current_account), alert: "That resident can't be added as a guest here"
  end

  def update
    membership = current_account.guest_memberships.find(params[:id])
    invited = GuestMembership.boolean_param(guest_membership_source[:invite_to_new_conversations])
    if invited.nil?
      redirect_to account_agents_path(current_account), alert: "Could not update guest settings"
      return
    end

    membership.update!(invite_to_new_conversations: invited)
    audit("update_guest_resident", membership, agent_id: membership.agent_id, invite_to_new_conversations: membership.invite_to_new_conversations)
    redirect_to account_agents_path(current_account)
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

  private

  def guest_membership_source
    params[:guest_membership].is_a?(ActionController::Parameters) ? params[:guest_membership] : params
  end

end
