# A resident's scheduled runs (wakes and memory aggregations) have no room to
# fail in. The conversation notice (RunFailureNotice, #649) tells the people
# of a room when a resident can't answer there; a wake that fails has no
# room, so until this nobody was told. Four of the six residents born since
# 3 Oct 2026 failed every scheduled run for days (a spent allowance, a key
# never set, a key refused) and the first person to know was reading the
# host by hand.
#
# From the second consecutive failed scheduled run the streak is recorded as
# an audit row, and the owner sees the resident in the navbar's black count
# (ExpiredProviderSubscriptions#summary, beside expired subscriptions), with
# the resident listed under "Failing residents" in the account menu, linking
# to its Runs tab. When a scheduled run completes again a closing row is
# written and the resident drops out of the count. The rows are the latch: a
# streak with no closing row is open, and an open streak is never recorded
# twice however long it lasts. A completed conversation run does not close
# it: a resident can answer in rooms while every wake fails, and that is
# exactly the failure worth showing.
#
# Until 31 Oct 2026 (#677) this opened a conversation in Main for each
# streak; Daniel found that the wrong tool for the job ("a whole
# conversation"), so it is a count, not a conversation.
#
# This reads terminal failed runs. It says nothing about the recall or
# journal hooks that run inside a run; a hook can fail inside a completed
# run, and that needs different evidence.
#
# Nothing is recorded for a resident asleep for billing, switched off, or
# under a failed-roll hold: each already has its own notice.
class ScheduledRunFailureNotice

  FAILING = "scheduled_runs_failing".freeze
  RECOVERED = "scheduled_runs_completing".freeze

  # The latest failing streak of this resident not closed by a recovery.
  def self.open_streak(agent)
    ended = AuditLog.where(action: RECOVERED, auditable: agent)
      .pluck(Arel.sql("data->>'streak_id'")).compact.map(&:to_i)
    AuditLog.where(action: FAILING, auditable: agent).where.not(id: ended).order(:id).last
  end

  # How many scheduled rows one look reads back before calling the streak
  # truncated. A method so a test can make truncation cheap.
  def self.scan_budget = Agents::RunFailureStreak::MAX_SCAN

  # Called with every finished scheduled run. Never raises into the caller:
  # a notice that can't be written must not fail the run's own bookkeeping.
  def self.observe!(run)
    new(run).observe!
  rescue StandardError => error
    Rails.logger.warn "[ScheduledRunFailure] run #{run.id}: #{error.class}: #{error.message}"
    nil
  end

  def initialize(run)
    @run = run
    @agent = run.agent
  end

  # Read, decide and write under a lock on the resident's row. The decision
  # is made from the runs table, ordered by (finished_at, id), never from the
  # run this job was handed: jobs arrive late, twice or out of order, and a
  # replayed old failure or a delayed old completion must not reopen or close
  # a streak the runs table no longer has. The run that triggered the job is
  # only the occasion to look.
  def observe!
    @agent.with_lock do
      current = Agents::RunFailureStreak.call(@agent, kind: :scheduled, max_scan: self.class.scan_budget,
        batch: [ Agents::RunFailureStreak::BATCH, self.class.scan_budget ].min)
      open = self.class.open_streak(@agent)
      if open && (success = first_completed_after(open))
        completing_again!(open, success)
        open = nil
      end
      failing!(current) if open.nil? && current.count >= 2 && !announced?(current) && worth_saying?
    end
  end

  def failing!(streak)
    # A truncated streak has no known start: no time is stored, and the
    # anchor for finding its recovery is the oldest failure the scan saw in
    # it, never the run whose job happened to ask (which may be old).
    AuditLog.create!(user: nil, account: @agent.account, action: FAILING, auditable: @agent,
      data: { run_id: @run.id, first_run_id: streak.first_run_id,
              anchor_run_id: streak.first_run_id || streak.oldest_seen_id, since: streak.since&.iso8601,
              count: streak.count, category: streak.categories.first || "unknown" })
    refresh_owner_count!
  end

  def completing_again!(streak, success)
    AuditLog.create!(user: nil, account: @agent.account, action: RECOVERED, auditable: @agent,
      data: { streak_id: streak.id, run_id: success.id, at: success.finished_at.iso8601 })
    refresh_owner_count!
  end

  private

  # This streak was announced before (and since closed): its first failed run
  # is already on a notice, so a late job can't announce it again.
  def announced?(current)
    current.first_run_id &&
      AuditLog.where(action: FAILING, auditable: @agent).where("data->>'first_run_id' = ?", current.first_run_id.to_s).exists?
  end

  # The completed scheduled run that ended the open streak: the first one
  # finishing after the streak's first failure (or, for a streak opened
  # without a known start, after the oldest failure the scan saw in it). Scanned oldest
  # first with no row cap, so any number of later failures can't push it out
  # of reach, and the duration on the recovery line ends where the streak
  # did. Nil when there is none yet.
  def first_completed_after(open)
    opener = AgentRuntimeInteraction.find_by(id: open.data&.dig("anchor_run_id") || open.data&.dig("first_run_id"))
    scope = Agents::RunFailureStreak.scheduled_scope(@agent.agent_runtime_interactions.where.not(finished_at: nil))
    scope = scope.where("(finished_at, id) > (?, ?)", opener.finished_at, opener.id) if opener
    cursor = nil
    loop do
      page = cursor ? scope.where("(finished_at, id) > (?, ?)", *cursor) : scope
      rows = page.order(:finished_at, :id).limit(200).to_a
      found = rows.detect { |run| run.streak_outcome == :success }
      return found if found
      return if rows.size < 200

      cursor = [ rows.last.finished_at, rows.last.id ]
    end
  end

  def worth_saying?
    @agent.active? && !@agent.billing_held? && !ResidentSwitchedOffNotice.open_holds(@agent).exists?
  end

  # The navbar count is read from the audit rows on each page load; touching
  # the resident commits its account refresh marker so an open page updates.
  def refresh_owner_count!
    @agent.touch
  end

end
