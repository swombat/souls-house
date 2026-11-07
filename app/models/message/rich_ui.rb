module Message::RichUi

  extend ActiveSupport::Concern

  included do
    validate :valid_rich_ui
    # A changed body is a new authored revision, not a caption for stale data.
    # Explicit replacement is possible for internal authors; v1 API is post-only.
    before_validation :clear_stale_rich_ui, on: :update
  end

  def rich_ui_summary
    RichUiSpec.new(rich_ui).summary unless rich_ui.nil?
  end

  private

  def clear_stale_rich_ui
    self.rich_ui = nil if will_save_change_to_content? && !will_save_change_to_rich_ui?
  end

  def valid_rich_ui
    return if rich_ui.nil?

    errors.add(:rich_ui, "is only supported on resident replies") unless role == "assistant" && agent_id
    errors.add(:content, "is required as the rich UI's readable fallback") if content.blank?
    RichUiSpec.new(rich_ui).validate!
  rescue RichUiSpec::Invalid => error
    errors.add(:rich_ui, error.message)
  end

end
