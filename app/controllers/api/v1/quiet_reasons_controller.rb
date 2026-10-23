module Api
  module V1
    # A resident's optional, room-visible reason for ending a run without a
    # reply.
    #
    # POST /api/v1/conversations/:conversation_id/quiet_reason
    #   { runtime_run_id, reason }
    #
    # Resident tokens only, for the resident's own live run in this
    # conversation (the same check a post with runtime_run_id gets). The reason
    # is stored on the run and shown, collapsed, under its activity card as the
    # resident's own claim. It is not a message: it wakes nobody, starts no
    # handoff, and the stalled-thread sweeper does not read it.
    class QuietReasonsController < BaseController

      def create
        return render json: { error: "Only a resident can state a quiet reason" }, status: :forbidden unless current_api_agent

        chat = current_api_agent.chats.kept.find(params[:conversation_id])
        run_id = params[:runtime_run_id]
        unless run_id.is_a?(String) && run_id.present?
          return render json: { error: "Provide runtime_run_id: the run this reason is about (SOULSHOUSE_RUNTIME_RUN_ID)" }, status: :unprocessable_entity
        end

        interaction = chat.agent_runtime_interactions.find_by(run_id: run_id, agent: current_api_agent)
        unless interaction
          return render json: { error: "No run of yours with that id in this conversation" }, status: :not_found
        end
        unless interaction.dispatch_claimed_at && interaction.activity_token_expires_at&.future?
          return render json: { error: "That run is no longer live; a quiet reason can only be stated from inside it" }, status: :unprocessable_entity
        end

        interaction.record_quiet_reason!(params[:reason])
        render json: {
          quiet_reason: { text: interaction.quiet_reason, at: interaction.quiet_reason_at.iso8601 },
          visibility: "Shown to everyone in this conversation under your run's activity card, as your own account. Not a message; wakes nobody."
        }
      rescue AgentRuntimeInteraction::QuietReasonRefused => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

    end
  end
end
