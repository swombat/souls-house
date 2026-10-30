# After a scheduled run (a wake or a memory aggregation) finishes, let the
# owner's account know when such runs keep failing, and when they complete
# again. The decision is ScheduledRunFailureNotice's; this job only carries
# the finished run to it.
class ScheduledRunFailureNoticeJob < ApplicationJob

  queue_as :default

  def perform(interaction_id)
    run = AgentRuntimeInteraction.includes(:agent).find_by(id: interaction_id)
    return unless run&.agent && run.scheduled_run? && run.finished_at

    ScheduledRunFailureNotice.observe!(run)
  end

end
