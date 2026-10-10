# Every five minutes, the durable backstop for everything the request and
# job paths schedule "after commit" and could lose in a crash or a failed
# enqueue:
#
# - armed watches past their time expire (each posts one line, because
#   silence is the failure this feature exists to remove);
# - armed watches whose first reconcile never ran (still pending) or could
#   not establish status (error) are reconciled again;
# - verified webhook receipts never processed are replayed (bounded);
# - fulfilled or expired watches whose effects never completed are delivered
#   again with backoff, until RepositoryWatchDelivery::MAX_ATTEMPTS, after
#   which the watch reads "delivery failed".
#
# Every one of these is safe to repeat: fulfil! acts only on armed watches,
# and the deliver job checks each recorded effect before performing it.
class RepositoryWatchSweepJob < ApplicationJob

  BATCH = 200
  GRACE = 2.minutes

  queue_as :default

  def perform(now: Time.current)
    RepositoryWatch.armed.where(expires_at: ..now).find_each { |watch| watch.expire!(now: now) }

    RepositoryWatch.armed.where(reconcile_status: %w[pending error]).where(updated_at: ..(now - GRACE)).order(:id).limit(BATCH).each do |watch|
      RepositoryWatchReconcileJob.perform_later(watch.id)
    end

    RepositoryDelivery.outstanding.where(updated_at: ..(now - GRACE)).order(:id).limit(BATCH).each do |delivery|
      RepositoryDeliveryJob.perform_later(delivery.id)
    end

    RepositoryWatchDelivery.incomplete.where(updated_at: ..(now - GRACE)).order(:id).limit(BATCH).each do |delivery|
      RepositoryWatchDeliverJob.perform_later(delivery.repository_watch_id) if delivery.retry_due?(now)
    end
  end

end
