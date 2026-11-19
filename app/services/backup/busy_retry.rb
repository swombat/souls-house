module Backup
  # A resident that is busy when its backup comes round is never interrupted.
  # Until 19 Nov 2026 (#1029) that attempt also left nothing behind: the
  # nightly run logged ResidentBusy and moved on, no row was written and no
  # one came back, so only the freshness check could notice, a day late
  # (Lume, 18 Nov: a rhythm run from 04:00:13 to 04:23:26Z covered the 04:00
  # run). Now each busy attempt writes a row that says so (ok: false, so
  # nothing counts it as a backup) and queues another try, a few times over
  # the next two hours.
  module BusyRetry

    ATTEMPTS = 6
    WAIT = 20.minutes
    PREFIX = "Skipped: resident busy".freeze

    # The span a night's retries cover. A retry finds an ok backup taken
    # within it (a catch-up, or another path) and stands down.
    def self.window = WAIT * ATTEMPTS

    def self.record!(agent, error, attempt:)
      attempt = attempt.to_i.clamp(1, ATTEMPTS)
      last = attempt >= ATTEMPTS
      AgentBackupSnapshot.create!(agent: agent, restic_snapshot_id: "unknown", taken_at: Time.current, ok: false,
        stderr_tail: "#{PREFIX} (#{error.message}); attempt #{attempt} of #{ATTEMPTS}, " +
          (last ? "no more tries tonight" : "next try in #{WAIT.in_minutes.to_i} minutes"))
      AgentResticJob.set(wait: WAIT).perform_later(agent.id, busy_attempt: attempt + 1) unless last
    end

    def self.caught_up?(agent)
      agent.agent_backup_snapshots.where(ok: true).where("taken_at >= ?", window.ago).exists?
    end

  end
end
