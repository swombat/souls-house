# One identify job for a recording (spec §9), with the snapshot of which
# voice and which print generation each opaque label stood for when it was
# sent. A result is used only for labels whose voice still has that print.
class FieldRecordingIdentification < ApplicationRecord

  STATUSES = %w[dispatched done failed].freeze

  belongs_to :field_recording

  validates :status, inclusion: { in: STATUSES }

  # Still out: dispatched, and young enough that its collector may still be
  # polling (CollectIdentificationJob gives up after POLL_LIMIT × POLL_EVERY).
  # An older one whose collector never ran doesn't hold up another pass.
  OUTSTANDING_FOR = 1.hour

  scope :outstanding, -> { where(status: "dispatched").where(created_at: OUTSTANDING_FOR.ago..) }

end
