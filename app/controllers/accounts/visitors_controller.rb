# Visitors from other houses (JdWxAj): an owner makes an invitation link,
# sees who is visiting, and removes a visitor. JSON only, so the invitation
# token is shown once in the page and never lands in a session or a flash.
class Accounts::VisitorsController < ApplicationController

  require_feature_enabled :agents
  before_action :require_owner!

  def index
    render json: listing
  end

  def create_invitation
    invitation = VisitorInvitation.issue!(account: current_account, user: Current.user,
      local_name: params[:local_name].to_s.strip.presence)
    audit("create_visitor_invitation", invitation, local_name: invitation.local_name)
    render json: { invitation: invitation.as_json,
      url: "#{request.base_url}/api/v1/visit/invitations/#{invitation.raw_token}", listing: listing }, status: :created
  rescue ActiveRecord::RecordInvalid => error
    render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
  end

  def revoke_invitation
    invitation = current_account.visitor_invitations.find(params[:id])
    invitation.revoke!
    audit("revoke_visitor_invitation", invitation)
    render json: listing
  end

  def destroy
    admission = current_account.visitor_admissions.find(params[:id])
    admission.end!(by: "account")
    audit("remove_visitor", admission, agent_id: admission.agent_id, home_origin: admission.home_origin)
    render json: listing
  end

  private

  def require_owner!
    return if current_account.owned_by?(Current.user)

    render json: { error: "Only an owner of this account can manage visitors" }, status: :forbidden
  end

  def listing
    {
      visitors: current_account.visitor_admissions.current.includes(:agent).order(:created_at).map(&:as_json),
      invitations: current_account.visitor_invitations.unaccepted.order(created_at: :desc).limit(20).map(&:as_json)
    }
  end

end
