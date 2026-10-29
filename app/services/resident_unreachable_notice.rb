# The house probes every externally hosted resident every five minutes
# (AgentHealthCheckJob) and writes the verdict to the row. Until this, nothing
# read it to tell anyone: the only consumer was the "currently unreachable"
# line a person got if they happened to talk to the resident while it was down
# (ExternalAgentResponseRequest#notify_unreachable). On 28 Oct Claude's
# container restarted 537 times over nine hours and nobody in the house was
# told; the owner finds out by trying to use the resident.
#
# Now, at THRESHOLD consecutive failed probes (fifteen minutes), the people of
# the resident's home account are told once, in a conversation of its own in
# Main with the resident in it (a system line wakes nobody), with an audit entry
# as the record; and once more, in the same conversation, when the probe passes
# again. The audit rows are the latch: an outage with no "reachable again" row
# is open, and an open outage is never announced twice however long it lasts.
#
# Nothing is said about a resident asleep for billing (its container is stopped
# on purpose, and the asleep banner already says so), a resident switched off
# (inactive: its runtime being down is nobody's problem until it is switched
# back on), or a resident under a failed-roll hold (ResidentSwitchedOffNotice
# already said it). A recovery is said whenever an outage is open, so an owner
# who was told their resident was down is also told it is back.
class ResidentUnreachableNotice

  THRESHOLD = 3
  UNREACHABLE = "resident_unreachable".freeze
  REACHABLE = "resident_reachable_again".freeze

  # The latest outage of this resident that has not been closed by a recovery.
  def self.open_outage(agent)
    ended = AuditLog.where(action: REACHABLE, auditable: agent)
      .pluck(Arel.sql("data->>'outage_id'")).compact.map(&:to_i)
    AuditLog.where(action: UNREACHABLE, auditable: agent).where.not(id: ended).order(:id).last
  end

  # Called after every probe. Never raises into the health check: a notice that
  # can't be written must not stop the probing of every other resident.
  def self.observe!(agent)
    new(agent).observe!
  rescue StandardError => error
    Rails.logger.warn "[ResidentUnreachable] agent #{agent.id}: #{error.class}: #{error.message}"
    nil
  end

  def initialize(agent)
    @agent = agent
  end

  def observe!
    outage = self.class.open_outage(@agent)
    if @agent.health_state == "healthy"
      reachable_again!(outage) if outage
    elsif outage.nil? && @agent.health_state == "unhealthy" &&
        @agent.consecutive_health_failures >= THRESHOLD && worth_saying?
      unreachable!
    end
  end

  def unreachable!
    since = @agent.health_failing_since || @agent.last_health_check_at || Time.current
    Agent.transaction do
      chat = @agent.account.chats.create_with_message!(
        { title: "#{@agent.name} isn't reachable", manual_responses: true },
        agent_ids: [ @agent.id ], automatic_response: false
      )
      chat.messages.create!(role: "system", content: unreachable_text(since), notice_link: link)
      AuditLog.create!(user: nil, account: @agent.account, action: UNREACHABLE, auditable: @agent,
        data: { chat_id: chat.id, since: since.iso8601, kind: kind, failures: @agent.consecutive_health_failures,
                restart_count: @agent.runtime_restart_count })
    end
  end

  def reachable_again!(outage)
    chat = Chat.find_by(id: outage.data&.dig("chat_id"), account_id: @agent.account_id)
    at = Time.current
    Agent.transaction do
      chat ||= @agent.account.chats.create_with_message!(
        { title: "#{@agent.name} is reachable again", manual_responses: true },
        agent_ids: [ @agent.id ], automatic_response: false
      )
      chat.messages.create!(role: "system", content: reachable_text(outage, at), notice_link: link)
      AuditLog.create!(user: nil, account: @agent.account, action: REACHABLE, auditable: @agent,
        data: { outage_id: outage.id, chat_id: chat.id, at: at.iso8601 })
    end
  end

  def unreachable_text(since)
    name = @agent.name
    if kind == "restarting"
      "[System Notice] #{name}'s runtime keeps restarting, and has since #{time_label(since)}. " \
        "#{name} can't take turns while it does, even when a check happens to find it up. " \
        "Restarting #{name} from their settings may not help: a runtime that restarts on its own is " \
        "failing as it starts, and the house admin needs to look at what it says when it starts."
    else
      "[System Notice] #{name}'s runtime hasn't answered the house since #{time_label(since)}. " \
        "#{name} can't take turns until it does. Restarting #{name} from their settings usually fixes it; " \
        "if it doesn't, the house admin can see what went wrong."
    end
  end

  def reachable_text(outage, at)
    since = Time.zone.parse(outage.data&.dig("since").to_s) || outage.created_at
    "[System Notice] #{@agent.name}'s runtime is answering again as of #{time_label(at)}, " \
      "after #{ActionController::Base.helpers.distance_of_time_in_words(since, at)} unreachable."
  end

  private

  def worth_saying?
    @agent.active? && !@agent.billing_held? && !ResidentSwitchedOffNotice.open_holds(@agent).exists?
  end

  def kind
    @agent.health_failure_kind == "restarting" ? "restarting" : "unanswered"
  end

  def link
    { label: "Settings", path: Rails.application.routes.url_helpers.edit_account_agent_path(@agent.account, @agent, tab: "settings") }
  end

  def time_label(at)
    zone = ActiveSupport::TimeZone[@agent.account.owner&.timezone.to_s] || ActiveSupport::TimeZone["UTC"]
    at.in_time_zone(zone).strftime("%-d %b %H:%M %Z")
  end

end
