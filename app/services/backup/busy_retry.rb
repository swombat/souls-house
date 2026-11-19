module Backup
  # A resident that is busy when its backup comes round is never interrupted.
  # Until 19 Nov 2026 (#1029) that attempt also left nothing behind: the
  # nightly run logged ResidentBusy and moved on, no row was written and no
  # one came back, so only the freshness check could notice, a day late
  # (Lume, 18 Nov: a rhythm run from 04:00:13 to 04:23:26Z covered the 04:00
  # run). Now each busy attempt writes a row that says so (ok: false, so
  # nothing counts it as a backup) and queues another try, a few times over
  # the next two hours.
  #
  # The retry is queued before the row is written, and the row names the
  # job. A row is not proof that a retry is owed to someone (Mira, #1036):
  # only a queued job that has neither run nor failed is. If the queue
  # refuses the job, the row says so and claims nothing.
  module BusyRetry

    ATTEMPTS = 6
    WAIT = 20.minutes
    PREFIX = "Skipped: resident busy".freeze
    LAST = "no more tries tonight".freeze
    JOB = /\[retry job ([0-9a-f-]{36})\]\z/

    # The span a night's retries cover. A retry finds an ok backup taken
    # within it (a catch-up, or another path) and stands down.
    def self.window = WAIT * ATTEMPTS

    def self.record!(agent, error, attempt:)
      attempt = attempt.to_i.clamp(1, ATTEMPTS)
      note = "#{PREFIX} (#{error.message}); attempt #{attempt} of #{ATTEMPTS}, "
      note += if attempt >= ATTEMPTS
        LAST
      else
        job = enqueue(agent, attempt + 1)
        job ? "next try in #{WAIT.in_minutes.to_i} minutes [retry job #{job.job_id}]" : "the next try could not be queued"
      end
      AgentBackupSnapshot.create!(agent: agent, restic_snapshot_id: "unknown", taken_at: Time.current, ok: false,
        stderr_tail: note)
    end

    def self.enqueue(agent, attempt)
      job = AgentResticJob.set(wait: WAIT).perform_later(agent.id, busy_attempt: attempt)
      job if job && job.successfully_enqueued? != false
    rescue StandardError => error
      Rails.logger.error("Backup retry for agent #{agent.id} could not be queued: #{error.class}")
      nil
    end

    # Whether this skip row still stands for owed work: it was the last try,
    # or the retry it names is queued and has neither run nor failed.
    def self.owed?(row)
      return true if row.stderr_tail.to_s.include?(LAST)

      job_id = row.stderr_tail.to_s[JOB, 1]
      job_id.present? && retry_pending?(job_id)
    end

    def self.retry_pending?(job_id)
      SolidQueue::Job.where(active_job_id: job_id, finished_at: nil).where.missing(:failed_execution).exists?
    end

    def self.caught_up?(agent)
      agent.agent_backup_snapshots.where(ok: true).where("taken_at >= ?", window.ago).exists?
    end

  end
end
