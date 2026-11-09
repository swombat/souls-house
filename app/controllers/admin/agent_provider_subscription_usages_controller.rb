class Admin::AgentProviderSubscriptionUsagesController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def show
    agent = Agent.find(params[:agent_id])
    render json: Agents::SubscriptionUsageSnapshot.fetch(agent)
  rescue AgentProviderAuthClient::Error => e
    render json: { error: e.message }, status: e.status || :bad_gateway
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

  def current_account
    nil
  end

end
