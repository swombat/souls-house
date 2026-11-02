# Every minute: activate the commitments that are due (Commitment#activate!),
# then bring each activated commitment whose wake is still in the house's
# custody up to date (Commitment#sync_wake!): delivered once a run has read
# it, woken again if the wake was lost. Database work only; no model is asked
# whether anything deserves attention.
class CommitmentSweepJob < ApplicationJob

  def perform
    now = Time.current
    Commitment.due(now).find_each do |commitment|
      commitment.activate!(now: now)
    rescue StandardError => error
      Rails.logger.error "[CommitmentSweepJob] activate #{commitment.id}: #{error.class}: #{error.message}"
    end
    Commitment.wake_in_custody.find_each do |commitment|
      commitment.sync_wake!
    rescue StandardError => error
      Rails.logger.error "[CommitmentSweepJob] sync #{commitment.id}: #{error.class}: #{error.message}"
    end
  end

end
