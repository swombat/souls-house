class ResidentTurnDispatchJob < ApplicationJob

  queue_as :resident_dispatch

  def perform
    ResidentTurn.admit!
    # This is also the durable recovery path for a process dying between
    # admission and job enqueue, or a lost callback/poll job.
    ResidentTurn.occupying_capacity.where("checked_at IS NULL OR checked_at < ?", 20.seconds.ago)
      .pluck(:id).each do |id|
        scheduled = ResidentTurn.where(id: id)
          .where("poll_claimed_until IS NULL OR poll_claimed_until < ?", Time.current)
          .where("checked_at IS NULL OR checked_at < ?", 20.seconds.ago)
          .update_all(checked_at: Time.current)
        ResidentTurnPollJob.perform_later(id) if scheduled == 1
      end
  end

end
