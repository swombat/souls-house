# A pending "remember this voice" (spec §9): who agreed, which sample, and,
# after "use it", the vendor job. Forget deletes it; every step rechecks it.
class FieldVoiceEnrolment < ApplicationRecord

  include ObfuscatesId

  STATUSES = %w[previewing dispatched].freeze

  belongs_to :account
  belongs_to :field_voice
  belongs_to :field_recording_speaker
  belongs_to :consented_by, polymorphic: true, optional: true

  has_one_attached :sample

  validates :status, inclusion: { in: STATUSES }

  before_destroy { sample.purge_later if sample.attached? }

  def expired?(now = Time.current) = expires_at <= now

end
