# Every few minutes: judge quiet rooms (StalledThreadSweeper). Does nothing
# while Setting#stalled_sweep_minutes is 0.
class StalledThreadSweepJob < ApplicationJob

  queue_as :default
  limits_concurrency to: 1, key: "stalled-thread-sweep"
  discard_on UtilityInference::MissingCredentials

  def perform
    StalledThreadSweeper.new.call
  end

end
