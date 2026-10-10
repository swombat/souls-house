# Says when production stops following master, once, and when it recovers.
#
# Deploy failures that leave the host gate latched make every later automatic
# deploy fail too, and the only witness used to be the Actions run list. This
# check catches the absence of progress: every few minutes it compares what
# is running (DeployInfo) with the recent deploy runs (HouseDeploy) and keeps
# one DeployAlarmState row.
#
#   stuck   - the newest finished automatic deploy failed for a commit that
#             isn't running, or production has been behind master for
#             GRACE with no deploy run in flight. One Honeybadger notice per
#             episode (per master sha).
#   unknown - can't tell (GitHub unreachable, dirty build, not an ancestor).
#             Never raises the alarm by itself; after GRACE the banner says
#             so in a neutral voice, because no information is not "fine".
#   ok      - level with master, or a deploy is running.
#
# Nothing here touches the host gate: recovery stays an operator's act.
class DeployAlarm

  class ProductionBehindMaster < StandardError; end

  GRACE = 30.minutes
  # The job runs every 5 minutes; a row older than this means it has stopped.
  STALE_AFTER = 20.minutes
  ACTIVE_STATUSES = %w[queued in_progress waiting requested pending].freeze
  # "cancelled" is left out on purpose: the deploy concurrency group cancels
  # a waiting run when a newer one arrives, and that is not a failure.
  FAILED_CONCLUSIONS = %w[failure timed_out startup_failure].freeze
  # Workflows whose success puts a new Rails build on the host and clears the
  # gate. (Runtime and Chaos deploys don't touch the Rails app.)
  RAILS_WORKFLOWS = [ "rails", "both", HouseDeploy::AUTOMATIC[:key] ].freeze
  RUNBOOK_URL = "https://github.com/swombat/souls-house/blob/master/docs/operations/github-deployments.md" \
    "#completion-interruptions-and-ordinary-recovery".freeze

  def self.check!(now: Time.current)
    record = DeployAlarmState.current
    new(record:, summary: DeployInfo.summary, deploys: HouseDeploy.status(limit: 20), now:).apply!
  rescue StandardError => e
    Rails.logger.error("[DeployAlarm] check failed: #{e.class}: #{e.message}")
    # last_checked_at is left alone, so a check that keeps failing goes stale
    # and the banner says so.
    record.update_columns(last_error: "#{e.class}: #{e.message}".truncate(1000), updated_at: now) if record&.persisted?
    nil
  end

  # What the Site Admin surfaces show. banner is true only when someone
  # should look: stuck, unknown for GRACE, or the check itself gone quiet.
  def self.payload(now: Time.current)
    record = DeployAlarmState.first
    return nil unless record

    base = {
      deployed_short: record.short(record.deployed_sha),
      master_short: record.short(record.master_sha),
      behind_by: record.behind_by,
      last_run_url: record.last_run_url,
      last_checked_at: record.last_checked_at&.iso8601,
      deploys_path: "/admin/deploys",
      runbook_url: RUNBOOK_URL
    }

    if record.last_checked_at.nil? || record.last_checked_at < now - STALE_AFTER
      return base.merge(state: "unknown", since: record.last_checked_at&.iso8601, banner: true, stale: true,
        reason: "The deploy alarm hasn't completed a check#{" since then" if record.last_checked_at}.")
    end

    case record.state
    when "stuck"
      base.merge(state: "stuck", since: record.since&.iso8601, reason: record.reason, banner: true)
    when "unknown"
      since = record.unknown_since || record.since
      base.merge(state: "unknown", since: since&.iso8601, reason: record.reason, banner: since.present? && since <= now - GRACE)
    else
      base.merge(state: "ok", since: nil, reason: nil, banner: false)
    end
  end

  def initialize(record:, summary:, deploys:, now:)
    @record = record
    @summary = summary || {}
    @deploys = deploys || {}
    @now = now
  end

  def apply!
    previous = @record.state
    verdict, reason, run_url = evaluate
    attrs = {
      state: verdict,
      deployed_sha: deployed_sha,
      master_sha: master_sha,
      behind_by: behind_by,
      behind_since: behind_since,
      unknown_since: unknown_since,
      reason: reason,
      last_run_url: run_url,
      last_checked_at: @now,
      last_error: nil
    }

    case verdict
    when "stuck"
      # The episode is master's sha. When GitHub can't say where master is,
      # the episode already notified carries on; a blip must not start a new one.
      episode = master_sha || (%w[stuck unknown].include?(previous) && @record.notified_master_sha) || newest_automatic&.dig(:head_sha)
      same_episode = @record.since && (previous == "stuck" || (previous == "unknown" && @record.notified_master_sha.present? && @record.notified_master_sha == episode))
      attrs[:since] = same_episode ? @record.since : [ behind_since, @now ].compact.min
      # Only a notice Honeybadger accepted counts; a failed one is retried
      # on the next check.
      if (@record.notified_at.nil? || @record.notified_master_sha != episode) && notify!(attrs, episode)
        attrs[:notified_at] = @now
        attrs[:notified_master_sha] = episode
      end
    when "unknown"
      # Keep the notification fields: a GitHub blip in the middle of a stuck
      # episode must not cause a second notice for the same episode, and the
      # episode keeps its start time.
      attrs[:since] = %w[stuck unknown].include?(previous) && @record.since ? @record.since : @now
    else
      Rails.logger.info("[DeployAlarm] production follows master again (#{deployed_sha.to_s.first(7)})") if previous == "stuck"
      attrs.merge!(since: nil, reason: nil, notified_at: nil, notified_master_sha: nil)
    end

    @record.update!(attrs)
    @record
  end

  private

  def evaluate
    if (active = active_run)
      [ "ok", nil, active[:url] ]
    elsif behind_by == 0
      [ "ok", nil, nil ]
    elsif failed_automatic?
      run = newest_automatic
      [ "stuck", "Last automatic deploy (#{run[:head_sha]}) failed#{failed_step_phrase(run)}.", run[:url] ]
    elsif behind_by.nil?
      [ "unknown", unknown_reason, nil ]
    elsif @now - behind_since >= GRACE
      [ "stuck", "No deploy has run since master moved ahead.", newest_automatic&.dig(:url) ]
    else
      [ "ok", nil, nil ]
    end
  end

  def deployed_sha = @summary.dig(:deployed, :sha)
  def master_sha = @summary.dig(:master, :sha)
  def behind_by = @summary[:behind_by]

  def behind_since
    return nil unless behind_by.to_i >= 1

    @behind_since ||= @record.behind_since || @now
  end

  def unknown_since
    return nil unless behind_by.nil?

    @unknown_since ||= @record.unknown_since || @now
  end

  def runs
    Array(@deploys[:runs])
  end

  # A deploy in flight counts only if it is deploying master as it is now.
  # A run for an older commit (or any run while master is unknown) says
  # nothing about whether production will catch up.
  def active_run
    return nil if master_sha.blank?

    runs.find { |run| ACTIVE_STATUSES.include?(run[:status].to_s) && same_commit?(run[:head_sha], master_sha) }
  end

  # HouseDeploy carries 7-character shas; DeployInfo carries full ones.
  def same_commit?(short, full)
    short = short.to_s
    short.match?(/\A\h{7,}\z/) && full.to_s.start_with?(short)
  end

  def newest_automatic
    @newest_automatic ||= runs
      .select { |run| run[:workflow] == HouseDeploy::AUTOMATIC[:key] && run[:status] == "completed" }
      .max_by { |run| run[:created_at].to_s }
  end

  # The newest finished automatic deploy failed, for a commit that isn't the
  # one running, and no Rails deploy has succeeded since. (Restarting a
  # process on the same image proves nothing: only a later successful deploy
  # shows the gate was cleared.)
  def failed_automatic?
    run = newest_automatic
    return false unless run && FAILED_CONCLUSIONS.include?(run[:conclusion].to_s)
    return false if same_commit?(run[:head_sha], deployed_sha)

    failed_at = parse_time(run[:updated_at]) || parse_time(run[:created_at])
    runs.none? { |later|
      RAILS_WORKFLOWS.include?(later[:workflow]) && later[:status] == "completed" && later[:conclusion] == "success" &&
        !%w[superseded not_deployed].include?(later[:outcome].to_s) && failed_at && (parse_time(later[:created_at]) || failed_at) > failed_at
    }
  end

  def failed_step_phrase(run)
    step = failed_step(run)
    step ? " at “#{step}”" : ""
  end

  # The name of the step that failed, from the run's jobs. Best effort: the
  # host's own words ("Deployment request unavailable") are only in the log.
  def failed_step(run)
    return nil unless run[:id]

    status, _headers, body = HouseDeploy.transport.call(:get, "/repos/#{HouseDeploy.repo}/actions/runs/#{run[:id]}/attempts/#{run[:attempt] || 1}/jobs", nil)
    return nil unless status == 200 && body.is_a?(Hash)

    Array(body["jobs"]).flat_map { |job| Array(job["steps"]) }.find { |step| step["conclusion"] == "failure" }&.dig("name")
  rescue StandardError
    nil
  end

  def unknown_reason
    if @summary[:deployed].nil? then "Can't read the running build's revision."
    elsif @summary.dig(:deployed, :dirty) then "The running build has uncommitted changes."
    elsif @summary[:master].nil? then "GitHub didn't say where master is."
    else "GitHub couldn't compare the running build with master."
    end
  end

  def notify!(attrs, episode)
    context = {
      deployed_sha: deployed_sha,
      master_sha: master_sha,
      behind_by: behind_by,
      reason: attrs[:reason],
      last_run_url: attrs[:last_run_url],
      since: attrs[:since]&.iso8601
    }
    message = "Production is on #{deployed_sha.to_s.first(7).presence || "an unknown build"}" \
      "#{", #{behind_by} behind master" if behind_by}. #{attrs[:reason]}"
    Honeybadger.notify(ProductionBehindMaster.new(message), context: context, fingerprint: "deploy-alarm-#{episode}")
    true
  rescue StandardError => e
    Rails.logger.error("[DeployAlarm] Honeybadger notification failed: #{e.class}: #{e.message}")
    false
  end

  def parse_time(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

end
