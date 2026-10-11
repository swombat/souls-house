class HouseInferenceCall < ApplicationRecord

  belongs_to :house_inference_grant
  validates :charge_usd, numericality: { greater_than_or_equal_to: 0 }

  # Idempotent. Missing/ambiguous usage retains the conservative charge; a crash
  # leaves pending admission blocked until an operator reconciles that call.
  def settle!(usage = nil, upstream_id: nil)
    with_lock do
      return unless status == 'pending'
      # BYOK and rounding (never down) live in HouseInference::UsageCost. A
      # BYOK call without a usable upstream cost fails closed as before.
      cost, byok = HouseInference::UsageCost.call(usage)
      known = !cost.nil?
      outcome = if (byok && !known) || (known && cost > charge_usd)
        'overrun'
      else
        known ? 'settled' : 'uncertain'
      end
      update!(charge_usd: known ? cost : charge_usd, status: outcome, upstream_id: upstream_id)
    end
  end

end
