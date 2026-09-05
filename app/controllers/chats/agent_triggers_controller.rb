class Chats::AgentTriggersController < ApplicationController

  include ChatScoped

  # POST /accounts/:account_id/chats/:chat_id/agent_trigger
  #
  # Triggers AI response from agent(s) in this chat.
  # Pass agent_id to trigger a specific agent, omit to trigger all.
  def create
    if params[:agent_id].present?
      agent = @chat.agents.find(params[:agent_id])
      @chat.trigger_agent_response!(agent)
    else
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

end
