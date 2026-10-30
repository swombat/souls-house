# A resident's scheduled runs (wakes and memory aggregations) have no room to
# fail in. The conversation notice (RunFailureNotice, #649) tells the people
# of a room when a resident can't answer there; a wake that fails has no
# room, so until this nobody was told. Four of the six residents born since
# 3 Oct 2026 failed every scheduled run for days (a spent allowance, a key
# never set, a key refused) and the first person to know was reading the
# host by hand.
#
# From the second consecutive failed scheduled run, the people of the
# resident's home account are told once, in a conversation of its own in
# Main with the resident in it (a system line wakes nobody), with an audit
# entry as the record; and once more, in the same conversation, when a
# scheduled run completes again. The audit rows are the latch: a streak with
# no "completing again" row is open, and an open streak is never announced
# twice however long it lasts. A completed conversation run does not close
# it: a resident can answer in rooms while every wake fails, and that is
# exactly the failure worth a line.
#
# This reads terminal failed runs. It says nothing about the recall or
# journal hooks that run inside a run; a hook can fail inside a completed
# run, and that needs different evidence.
#
# Nothing is said about a resident asleep for billing, switched off, or under
# a failed-roll hold: each already has its own notice.
class ScheduledRunFailureNotice

  FAILING = "scheduled_runs_failing".freeze
  RECOVERED = "scheduled_runs_completing".freeze

  # The latest failing streak of this resident not closed by a recovery.
  def self.open_streak(agent)
    ended = AuditLog.where(action: RECOVERED, auditable: agent)
      .pluck(Arel.sql("data->>'streak_id'")).compact.map(&:to_i)
    AuditLog.where(action: FAILING, auditable: agent).where.not(id: ended).order(:id).last
  end

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

  # Read, decide and write under a lock on the resident's row: two scheduled
  # runs can finish close together (the 02:00 memory run and a wake), and
  # without the lock both could open a streak, or both close one.
  def observe!
    @agent.with_lock do
      open = self.class.open_streak(@agent)
      case @run.streak_outcome
      when :success
        completing_again!(open) if open
      when :failure
        next if open || !worth_saying?

        streak = Agents::RunFailureStreak.call(@agent, through: @run, kind: :scheduled)
        failing!(streak) if streak.count >= 2
      end
    end
  end

  def failing!(streak)
    since = streak.since || @run.started_at
    Agent.transaction do
      chat = @agent.account.chats.create_with_message!(
        { title: "#{@agent.name}'s scheduled runs are failing", manual_responses: true },
        agent_ids: [ @agent.id ], automatic_response: false
      )
      chat.messages.create!(role: "system", content: failing_text(streak, since), notice_link: link)
      AuditLog.create!(user: nil, account: @agent.account, action: FAILING, auditable: @agent,
        data: { chat_id: chat.id, run_id: @run.id, since: since.iso8601, count: streak.count,
                category: @run.failure_category, trigger_kind: @run.trigger_kind })
    end
  end

  def completing_again!(streak)
    chat = Chat.find_by(id: streak.data&.dig("chat_id"), account_id: @agent.account_id)
    at = @run.finished_at
    Agent.transaction do
      chat ||= @agent.account.chats.create_with_message!(
        { title: "#{@agent.name}'s scheduled runs are completing again", manual_responses: true },
        agent_ids: [ @agent.id ], automatic_response: false
      )
      chat.messages.create!(role: "system", content: completing_text(streak, at), notice_link: link)
      AuditLog.create!(user: nil, account: @agent.account, action: RECOVERED, auditable: @agent,
        data: { streak_id: streak.id, chat_id: chat.id, run_id: @run.id, at: at.iso8601 })
    end
  end

  def failing_text(streak, since)
    name = @agent.name
    cause = RunFailureNotice::NO_REPLY_CAUSES.fetch(@run.failure_category)
    tally = if streak.truncated
      "#{streak.count} or more failed scheduled runs in a row"
    else
      "#{streak.count.ordinalize} failed scheduled run in a row since #{time_label(since)}"
    end
    "[System Notice] #{name}'s scheduled runs are failing: #{cause} (#{tally}). " \
      "#{name}'s wakes and memory sessions don't happen while they fail; conversations are separate and may still work. " \
      "The Runs tab shows each run."
  end

  def completing_text(streak, at)
    since = Time.zone.parse(streak.data&.dig("since").to_s) || streak.created_at
    "[System Notice] #{@agent.name}'s scheduled runs are completing again as of #{time_label(at)}, " \
      "after #{ActionController::Base.helpers.distance_of_time_in_words(since, at)} of failures."
  end

  private

  def worth_saying?
    @agent.active? && !@agent.billing_held? && !ResidentSwitchedOffNotice.open_holds(@agent).exists?
  end

  # The resident's Runs tab, which the people of its home account can open.
  def link
    { label: "Why?", path: Rails.application.routes.url_helpers.edit_account_agent_path(@agent.account, @agent, tab: "interactions") }
  end

  def time_label(at)
    zone = ActiveSupport::TimeZone[@agent.account.owner&.timezone.to_s] || ActiveSupport::TimeZone["UTC"]
    at.in_time_zone(zone).strftime("%-d %b %H:%M %Z")
  end

end
