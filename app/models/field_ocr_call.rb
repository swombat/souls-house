# One paid page transcription for Field OCR (FieldOcr). Reserved before the
# call with a conservative charge, then settled with what OpenRouter says it
# cost. A call that reached the model but failed, or whose cost is unknown,
# keeps its charge, so it still counts against the house's daily ceiling. A
# reservation released before anything was sent (the page couldn't be
# rendered) is `failed` at no charge.
class FieldOcrCall < ApplicationRecord

  STATUSES = %w[reserved settled failed uncertain].freeze

  belongs_to :account
  belongs_to :field_file

  validates :status, inclusion: { in: STATUSES }
  validates :charge_usd, numericality: { greater_than_or_equal_to: 0 }

  scope :on, ->(day) { where(day: day) }

  def settle!(usage, upstream_id: nil)
    with_lock do
      return unless status == "reserved"

      cost, = HouseInference::UsageCost.call(usage)
      if cost
        update!(status: "settled", charge_usd: cost, upstream_id: upstream_id)
      else
        update!(status: "uncertain", upstream_id: upstream_id)
      end
    end
  end

  # The model was asked and something went wrong: keep the charge.
  def fail!
    with_lock { update!(status: "failed") if status == "reserved" }
  end

  # Nothing was sent: give the reservation back.
  def release!
    with_lock { update!(status: "failed", charge_usd: 0) if status == "reserved" }
  end

end
