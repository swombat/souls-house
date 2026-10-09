class Chats::AgentTriggersController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/agent_trigger
  #
  # Triggers AI response from agent(s) in this chat.
  # Pass agent_id to trigger a specific agent, omit to trigger all.
  def create
    requested_by = Current.user.full_name.presence || Current.user.email_address.split("@").first
    queued = []
    if params[:agent_id].present?
      agent = @chat.agents.find(params[:agent_id])
      return if inference_unavailable?([ agent ])
      queued << agent if @chat.request_agent_response!(agent, requested_by: requested_by, user: Current.user) == :queued
    else
      return if inference_unavailable?(@chat.agents)
      queued = @chat.request_all_agents_response!(requested_by: requested_by, user: Current.user)[:queued]
    end

    notice = queued.any? ? "#{queued.map(&:name).to_sentence} #{queued.one? ? "is" : "are"} still responding, and will be woken again when that finishes." : nil
    respond_to do |format|
      format.html { redirect_to account_chat_path(current_account, @chat), notice: notice }
      format.json { render json: { queued: queued.map { |a| { id: a.to_param, name: a.name } } } }
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

    message = Agents::InferenceAvailability::MISSING_CREDENTIALS_MESSAGE
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
