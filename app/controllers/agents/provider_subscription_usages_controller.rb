class Agents::ProviderSubscriptionUsagesController < ApplicationController

  include AgentScoped

  before_action :require_account_owner!

  def show
    render json: AgentProviderAuthClient.new(@agent).usage(
      provider: Agents::Sandbox.chaos_provider_for(@agent),
      model: Agents::Sandbox.chaos_model_for(@agent),
      refresh: ActiveModel::Type::Boolean.new.cast(params[:refresh])
    )
  rescue AgentProviderAuthClient::Error => e
    render json: { error: e.message }, status: e.status || :bad_gateway
  end

end
