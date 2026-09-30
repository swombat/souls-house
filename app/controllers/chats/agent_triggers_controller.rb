class Chats::AgentTriggersController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/agent_trigger
  #
  # Triggers AI response from agent(s) in this chat.
  # Pass agent_id to trigger a specific agent, omit to trigger all.
  def create
    if params[:agent_id].present?
      agent = @chat.agents.find(params[:agent_id])
      return if inference_unavailable?([ agent ])
      @chat.trigger_agent_response!(agent)
    else
      return if inference_unavailable?(@chat.agents)
      @chat.trigger_all_agents_response!
    end

    respond_to do |format|
      format.html { redirect_to account_chat_path(current_account, @chat) }
      format.json { head :ok }
    end
  rescue ArgumentError => e
    respond_to do |format|
      format.html { redirect_back_or_to account_chat_path(current_account, @chat), alert: e.message }
      format.json do
        render json: { error: e.message, code: e.respond_to?(:code) ? e.code : nil },
          status: e.is_a?(Agent::RuntimeAvailability::Unavailable) ? :conflict : :unprocessable_entity
      end
    end
  end

  private

  def inference_unavailable?(agents)
    agents.each do |agent|
      next unless agent.eligible_for_conversation? && HouseInference::Offering.find(agent.model_id)
      error = Agents::InferenceAvailability.house_error(agent)
      next unless error
      respond_to do |format|
        format.html { redirect_to account_chat_path(current_account, @chat), alert: error.message }
        format.json { render json: { error: error.message, code: error.code }, status: error.status }
      end
      return true
    end

    missing = agents.select do |agent|
      agent.eligible_for_conversation? && !HouseInference::Offering.find(agent.model_id) && !Agents::InferenceAvailability.available?(agent)
    end
    return false if missing.empty?

    message = "Edit the resident and set up credentials before asking them to respond."
    respond_to do |format|
      format.html { redirect_to account_chat_path(current_account, @chat), alert: message }
      format.json do
        render json: {
          error: message,
          code: "missing_credentials",
          agents: missing.map { |agent| { id: agent.to_param, name: agent.name } }
        }, status: :unprocessable_entity
      end
    end
    true
  end

end
