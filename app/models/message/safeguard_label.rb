# A resident's conversation post that the safeguard check labelled
# (docs/safeguard-conversations-spec.md §3). The message stays the resident's
# record (agent_id, run, costs); while the label stands, everything that
# presents or acts on authorship treats it as the house's.
module Message::SafeguardLabel

  extend ActiveSupport::Concern

  included do
    belongs_to :safeguard_detection, optional: true

    scope :without_safeguard_label, -> {
      left_joins(:safeguard_detection)
        .where(safeguard_detection_id: nil)
        .or(left_joins(:safeguard_detection).where.not(safeguard_detections: { reclaimed_at: nil }))
    }
  end

  def safeguard_labelled?
    safeguard_detection_id.present? && safeguard_detection.present? && !safeguard_detection.reclaimed?
  end

  # Authorship is derived from the detection row, so a reclaim changes what
  # every client renders without changing a message column. Take a sync
  # revision (native app) and refresh the room (web) explicitly.
  def announce_safeguard_label_change!
    update_columns_with_revision(updated_at: Time.current)
    ActiveRecord.after_all_transactions_commit { broadcast_refresh }
  end

  def safeguard
    detection = safeguard_detection
    return unless detection

    {
      detection_id: detection.to_param,
      agent_name: agent&.name,
      reclaimed: detection.reclaimed?,
      reclaim_reason: detection.reclaim_reason,
      explanation_path: SafeguardNoticeRenderer::EXPLANATION_PATH,
      reset_path: Rails.application.routes.url_helpers.message_safeguard_reset_path(self)
    }
  end

end
