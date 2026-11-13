# Every minute: activate the commitments that are due (Commitment#activate!),
# then bring each activated commitment whose wake is still in the house's
# custody up to date (Commitment#sync_wake!): delivered once a run has read
# it, woken again if the wake was lost. Database work only; no model is asked
# whether anything deserves attention.
class CommitmentSweepJob < ApplicationJob

  def perform
    now = Time.current
    admitted = Set.new
    # At most one restored promise per resident per sweep, not a backlog of
    # new conversations when an allowance resets. Owed rows remain visible.
    Commitment.due(now).includes(:agent).find_each(batch_size: 100) do |commitment|
      limited = recovery_limited?(commitment)
      next if limited && admitted.include?(commitment.agent_id)
      result = commitment.activate!(now: now)
      admitted << commitment.agent_id if limited && result.activated?
    rescue StandardError => error
      Rails.logger.error "[CommitmentSweepJob] activate #{commitment.id}: #{error.class}: #{error.message}"
    end
    Commitment.wake_in_custody.includes(:agent).find_each(batch_size: 100) do |commitment|
      retrying = commitment.wake_state == "retrying"
      limited = recovery_limited?(commitment)
      before_runs = commitment.wake_runs
      commitment.sync_wake!(allow_retry: !limited || !admitted.include?(commitment.agent_id))
      if limited && retrying && (commitment.wake_runs > before_runs || commitment.wake_state == "held")
        admitted << commitment.agent_id
      end
    rescue StandardError => error
      Rails.logger.error "[CommitmentSweepJob] sync #{commitment.id}: #{error.class}: #{error.message}"
    end
  end

  private

  def recovery_limited?(commitment)
    !commitment.essential? && (!commitment.agent.allowance_brake_threshold_percent.nil? ||
      commitment.waiting_reason == "skipped_allowance" || commitment.wake_reason.to_s.include?("skipped_allowance"))
  end

end
