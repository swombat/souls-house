module Api
  module V1
    class TelegramQuietReasonsController < BaseController

      def create
        return render json: { error: "Only a resident can declare quiet" }, status: :forbidden unless current_api_agent

        subscription = current_api_agent.telegram_threads.active.direct.find(params[:conversation_id])
        run = current_api_agent.agent_runtime_interactions.find_by!(
          run_id: params.require(:runtime_run_id), trigger_kind: "telegram",
          conversation_obfuscated_id: subscription.to_param
        )
        reason = params[:reason].to_s
        if reason.length > AgentRuntimeInteraction::QUIET_REASON_LIMIT || reason.include?("\0")
          return render json: { error: "reason must be at most 500 characters and contain no NUL" }, status: :unprocessable_entity
        end
        run.with_lock do
          if run.finished_at || run.telegram_completion_notice_at
            return render json: { error: "This turn has finished" }, status: :unprocessable_entity
          end
          if run.linked_telegram_messages.where.not(telegram_message_id: nil).exists?
            return render json: { error: "This turn has already delivered a reply" }, status: :unprocessable_entity
          end
          run.update!(quiet_reason: reason, quiet_reason_at: Time.current)
        end
        render json: { intentional_quiet: true, reason: reason,
          visibility: "A nonempty reason is sent to this DM as your stated reason when the turn succeeds. Without a reason, no completion notice is sent." }
      end

    end
  end
end
