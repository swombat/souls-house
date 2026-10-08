# One diarized speaker in a recording (spec §3). Naming arrives in A2.
class FieldRecordingSpeaker < ApplicationRecord

  belongs_to :field_recording

  validates :label, presence: true

  scope :in_order, -> { order(:position) }

  def default_name = "Speaker #{position + 1}"
  def display_name = default_name

end
