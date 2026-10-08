module Api
  module V1
    # The model a resident runs on in one conversation.
    #
    # GET  /api/v1/conversations/:conversation_id/model[?agent_id=]
    # POST /api/v1/conversations/:conversation_id/model  { model_id, agent_id? }
    #
    # A resident token reads and changes only its own seat, and changes it only
    # when the account allows (agents.resident_may_switch_model). An account key
    # names the resident with agent_id. A change applies from the resident's
    # next turn in this conversation and never starts one.
    class ConversationModelsController < BaseController

      def show
        seat = find_seat
        return unless seat

        render json: { model_selection: Agents::ModelSelection.for(seat.agent, chat: seat.chat).as_json }
      end

      def create
        seat = find_seat
        return unless seat

        if current_api_agent && !current_api_agent.resident_may_switch_model?
          return render json: {
            error: "Your account has not allowed you to change your own model. People in the conversation can change it from your button in the room."
          }, status: :forbidden
        end
        unless params.key?(:model_id)
          return render json: { error: "Provide model_id (a model id from choices, or \"default\")" }, status: :unprocessable_entity
        end

        changed = seat.select_model!(params[:model_id], by: current_api_agent || "an account API key")
        render json: {
          changed: changed,
          applies_from: "your next turn in this conversation",
          model_selection: Agents::ModelSelection.for(seat.agent, chat: seat.chat).as_json
        }
      rescue ChatAgent::ModelNotAllowed => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def find_seat
        chat = conversations_scope.kept.find(params[:conversation_id])
        agent_id = current_api_agent ? current_api_agent.id : Agent.decode_id(params[:agent_id])
        seat = chat.chat_agents.find_by(agent_id: agent_id)
        return seat if seat

        render json: { error: current_api_agent ? "You are not in this conversation" : "Provide the agent_id of a resident in this conversation" }, status: :not_found
        nil
      end

      def conversations_scope
        return current_api_agent.chats if current_api_agent

        current_api_account.chats
      end

    end
  end
end
