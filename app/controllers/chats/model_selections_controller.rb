# A person in the room chooses which model a resident runs on here.
# PATCH /accounts/:account_id/chats/:chat_id/model_selection
#   { agent_id, model_id }  — model_id "default" (or blank) follows the resident's default.
class Chats::ModelSelectionsController < ApplicationController

  include ChatScoped

  def update
    seat = @chat.chat_agents.find_by!(agent_id: Agent.decode_id(params[:agent_id]))
    seat.select_model!(params[:model_id], by: Current.user)
    render json: { model_selection: Agents::ModelSelection.for(seat.agent, chat: @chat).as_json }
  rescue ChatAgent::ModelNotAllowed => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

end
