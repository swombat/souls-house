module Message::Progress

  extend ActiveSupport::Concern

  included do
    before_destroy :preserve_progress_boundary
    before_discard :preserve_progress_boundary
  end

  # Legacy JSON fields remain readable; neither controls grouping or delivery.
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

  # A removed message must not join two previously separate groups, including
  # when the next linked resident post arrives only after the deletion. Keep the seam
  # on the preceding record; no deleted content or author needs to be retained.
  def preserve_progress_boundary
    previous = chat.messages.kept
      .where("created_at < :time OR (created_at = :time AND id < :id)", time: created_at, id: id)
      .reorder(created_at: :desc, id: :desc).first
    return unless previous&.role == "assistant" && previous.agent_id && previous.runtime_interaction_id

    # The seam is client-visible, so it takes a revision like any other change,
    # inside discard's transaction.
    previous.update_columns_with_revision(progress_break_after: true)
  end

end
