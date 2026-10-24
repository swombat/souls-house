class Agents::ProviderSubscriptionUsagesController < ApplicationController

  include AgentScoped

  def show
    render json: AgentProviderAuthClient.new(@agent).usage(
      provider: Agents::Sandbox.chaos_provider_for(@agent),
      model: Agents::Sandbox.chaos_model_for(@agent),
      refresh: ActiveModel::Type::Boolean.new.cast(params[:refresh])
    )
  rescue AgentProviderAuthClient::Error => e
    render json: { error: e.message }, status: e.status || :bad_gateway
  end

  private

  # Members see how much subscription is left for every resident who takes
  # part in their conversations, guests included. Everything else under
  # AgentScoped stays limited to residents hosted here.
  def set_agent
    @agent = current_account.conversation_agents.find(params[:agent_id])
  end

end
