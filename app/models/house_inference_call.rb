class HouseInferenceCall < ApplicationRecord

  belongs_to :house_inference_grant
  validates :charge_usd, numericality: { greater_than_or_equal_to: 0 }

  # Idempotent. Missing/ambiguous usage retains the conservative charge; a crash
  # leaves pending admission blocked until an operator reconciles that call.
  def settle!(usage = nil, upstream_id: nil)
    with_lock do
      return unless status == 'pending'
      cost = BigDecimal(usage['cost'].to_s, exception: false) if usage.is_a?(Hash)
      byok = usage.is_a?(Hash) && usage['is_byok'] == true
      known = !byok && cost&.finite? && cost >= 0
      cost = cost.ceil(8) if known # never round a fractional charge down in the ledger
      outcome = if byok || (known && cost > charge_usd)
        'overrun'
      else
        known ? 'settled' : 'uncertain'
      end
      update!(charge_usd: known ? cost : charge_usd, status: outcome, upstream_id: upstream_id)
    end
  end

end
