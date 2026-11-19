class FullBackupJob < ApplicationJob

  queue_as :default

  # fail_fast: true  — manual/interactive runs (db_backup:perform): any agent
  #                    failure aborts the run so the database dump is never
  #                    created over a knowingly incomplete agent backup set.
  # fail_fast: false — scheduled nightly runs: agent failures are recorded
  #                    (AgentBackupSnapshot ok: false) and logged, remaining
  #                    agents are still backed up, and the database dump always
  #                    runs. Restore is unaffected: it only ever uses the latest
  #                    *successful* snapshot recorded in the dump.
  #
  # A scheduled run that is interrupted (a deploy stops the worker) is run
  # again from the top by the queue. It then skips every resident already
  # backed up since this run was first queued, so each restart continues where
  # the last one stopped and the run gets to the database dump. Without this,
  # deploys closer together than one full pass kept it from ever finishing
  # (16 Nov 2026: four deploys in the hour after 4am).
  def perform(fail_fast: false)
    Agent.externally_hosted.where.not(uuid: nil).find_each do |agent|
      next if !fail_fast && (backed_up_in_this_run?(agent) || deferred_in_this_run?(agent))

      backup_agent!(agent, fail_fast)
    end

    # Its own job: a failed connector dump is a failed backup with its own
    # name, and the house dump below does not wait for it or fail with it.
    Backup::CommsTelegramDumpJob.perform_later
    DatabaseBackupJob.perform_now
  end

  private

  # enqueued_at is the time the schedule queued this run and survives a
  # restart; a run started by hand with perform_now has none and skips nobody.
  def backed_up_in_this_run?(agent)
    since = enqueued_at && Time.zone.parse(enqueued_at.to_s)
    since.present? && agent.agent_backup_snapshots.where(ok: true).where("taken_at >= ?", since).exists?
  end

  # Found busy earlier in this run and a retry is still owed (queued, not yet
  # run or failed): a restart must not start a second chain. A skip row whose
  # retry never got queued, or was lost, does not count (#1036).
  def deferred_in_this_run?(agent)
    since = enqueued_at && Time.zone.parse(enqueued_at.to_s)
    return false unless since

    row = agent.agent_backup_snapshots.where(ok: false).where("taken_at >= ?", since)
      .where("stderr_tail LIKE ?", "#{Backup::BusyRetry::PREFIX}%").order(:taken_at, :id).last
    row.present? && Backup::BusyRetry.owed?(row)
  end

  def backup_agent!(agent, fail_fast)
    Backup::AgentResticJob.perform_now(agent.id, force: fail_fast)
  rescue Backup::AgentRestic::ResidentBusy => e
    raise if fail_fast

    # Not a failure and not forgotten: a row says the resident was busy, and
    # a later try is queued (#1029).
    Rails.logger.info "Agent backup deferred for #{agent.name}: #{e.message}"
    Backup::BusyRetry.record!(agent, e, attempt: 1)
  rescue StandardError => e
    raise if fail_fast

    Rails.logger.error "Agent backup failed for #{agent.name}: #{e.class} - #{e.message}"
  end

end
