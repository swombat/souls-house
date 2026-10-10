# Every five minutes: expire armed watches past their time (each posts one
# line, because silence is the failure this feature exists to remove), and
# retry reconciling watches whose status GitHub could not establish.
class RepositoryWatchSweepJob < ApplicationJob

  queue_as :default

  def perform(now: Time.current)
    RepositoryWatch.armed.where(expires_at: ..now).find_each { |watch| watch.expire!(now: now) }
    RepositoryWatch.armed.where(reconcile_status: "error").where(updated_at: ..(now - 4.minutes)).find_each do |watch|
      RepositoryWatchReconcileJob.perform_later(watch.id)
    end
  end

end
