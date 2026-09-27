module Message::Progress

  extend ActiveSupport::Concern

  included do
    before_destroy :preserve_progress_boundary
    validate :valid_progress_message, on: :create
    validate :immutable_progress_content, on: :update
    validates :content, length: { maximum: 32_000 }, if: :progress_message?
  end

  def progress_run_id
    runtime_interaction&.run_id if progress_message?
  end

  def progress_status
    return unless progress_message?
    interaction = runtime_interaction
    return "Status unknown" unless interaction

    case interaction.execution_state
    when "completed" then "Wake ended"
    when "failed" then "Failed"
    when "timed_out" then "Timed out"
    when "cancelled" then "Cancelled"
    when "outcome_unknown", "busy" then "Interrupted"
    else
      interaction.execution_deadline_at&.future? && !interaction.finished_at? ? "In progress" : "Status unknown"
    end
  end

  private

  def valid_progress_message
    return unless progress_message?

    unless role == "assistant" && agent_id && runtime_interaction&.agent_id == agent_id && runtime_interaction.chat_id == chat_id
      errors.add(:progress_message, "requires the resident's own conversation run")
    end
    errors.add(:progress_message, "supports text only") if content.blank? || attachments.attached?
  end

  def immutable_progress_content
    if progress_message_in_database && will_save_change_to_content?
      errors.add(:content, "cannot edit a published progress message")
    end
  end

  # A removed message must not join two previously separate groups, including
  # when the next progress post arrives only after the deletion. Keep the seam
  # on the preceding record; no deleted content or author needs to be retained.
  def preserve_progress_boundary
    previous = chat.messages
      .where("created_at < :time OR (created_at = :time AND id < :id)", time: created_at, id: id)
      .reorder(created_at: :desc, id: :desc).first
    previous.update_column(:progress_break_after, true) if previous&.progress_message?
  end

end
