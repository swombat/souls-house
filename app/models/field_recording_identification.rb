# One identify job for a recording (spec §9), with the snapshot of which
# voice and which print generation each opaque label stood for when it was
# sent. A result is used only for labels whose voice still has that print.
class FieldRecordingIdentification < ApplicationRecord

  STATUSES = %w[dispatched done failed].freeze

  belongs_to :field_recording

  validates :status, inclusion: { in: STATUSES }

end
