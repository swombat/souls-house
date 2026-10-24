# After a conversation run fails (AgentRuntimeInteraction::FailureReport),
# tell the room from the second consecutive failure on. One notice per run,
# never for the first failure of a streak, never for a busy or lost run.
class RunFailureNoticeJob < ApplicationJob

  queue_as :default

  def perform(interaction_id)
    run = AgentRuntimeInteraction.includes(:agent, :chat).find_by(id: interaction_id)
    return unless run&.chat && run.agent && run.trigger_kind == "conversation"

    run.with_lock do
      next if run.failure_notice_message_id || run.streak_outcome != :failure

      streak = Agents::RunFailureStreak.call(run.agent, through: run)
      next if streak.count < 2

      notice = RunFailureNotice.post!(run, streak)
      run.update_columns(failure_notice_message_id: notice.id)
    end
  end

end
