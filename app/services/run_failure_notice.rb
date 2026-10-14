# The room's platform line when a resident's run fails again. It says what
# the people there need: that the resident didn't respond (or failed after a
# reply that stands), the run's safe category, and how long the streak is.
# It never carries run output or error text; "Why?" links to the run log for
# people who can open it.
class RunFailureNotice

  NO_REPLY_CAUSES = {
    "runtime_unavailable" => "its runtime couldn't be reached",
    "runtime_error" => "the run ended in an error",
    "timed_out" => "the run timed out",
    "unknown" => "the run failed and the cause isn't identified"
  }.freeze

  def self.post!(run, streak)
    new(run, streak).post!
  end

  def initialize(run, streak)
    @run = run
    @streak = streak
    @agent = run.agent
    @chat = run.chat
  end

  def post!
    @chat.messages.create!(role: "system", content: content, notice_link: link)
  end

  def content
    tally = if @streak.truncated
      # The scan stopped before the streak's start: a lower bound, no start time.
      "#{@streak.count} or more failed runs in a row"
    else
      "#{@streak.count.ordinalize} failed run in a row since #{since_label}"
    end
    if replied?
      ended = @run.failure_category == "timed_out" ? "timed out" : "ended with an error"
      "#{@agent.name}'s run #{ended} after replying (#{tally})."
    else
      "#{@agent.name} couldn't respond here: #{NO_REPLY_CAUSES.fetch(@run.failure_category)} (#{tally})."
    end
  end

  private

  # A reply that reached the room is never erased by the wording. Only a
  # visible reply this run posted in this room counts: not another run's
  # reply, a rhythm opening, a progress or streaming row, a discarded or
  # empty post, or unreclaimed safeguard-labelled house speech.
  def replied?
    replies = @run.linked_messages.kept
      .where(role: "assistant", agent_id: @agent.id, chat_id: @chat.id, progress_message: false, streaming: false)
      .without_safeguard_label
      .where.missing(:rhythm_occurrence)
    with_attachments = ActiveStorage::Attachment.where(record_type: "Message", name: "attachments").select(:record_id)
    replies.where("messages.content ~ '[^[:space:]]'").or(replies.where(id: with_attachments)).exists?
  end

  # The resident's Runs tab, which the people of its home account can open.
  # A guest resident's room gets no link they couldn't follow.
  def link
    return unless @chat.account_id == @agent.account_id

    { label: "Why?", path: Rails.application.routes.url_helpers.edit_account_agent_path(@agent.account, @agent, tab: "interactions") }
  end

  def since_label
    zone = ActiveSupport::TimeZone[@chat.account.owner&.timezone.to_s] || ActiveSupport::TimeZone["UTC"]
    since = @streak.since.in_time_zone(zone)
    format = since.to_date == @run.finished_at.in_time_zone(zone).to_date ? "%H:%M %Z" : "%-d %b %H:%M %Z"
    since.strftime(format)
  end

end
