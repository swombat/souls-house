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
      # With BYOK (Daniel's choice, 2026-10-10: cheaper than OpenRouter's
      # margin), OpenRouter's `cost` is only its own fee and the provider bills
      # its key directly. That provider charge is reported per call as
      # cost_details.upstream_inference_cost, so the call costs the house the
      # sum. A BYOK call without a usable upstream cost still can't be metered
      # and fails closed as before.
      cost = byok_total(cost, usage['cost_details']) if byok
      known = cost&.finite? && cost >= 0
      cost = cost.ceil(8) if known # never round a fractional charge down in the ledger
      outcome = if (byok && !known) || (known && cost > charge_usd)
        'overrun'
      else
        known ? 'settled' : 'uncertain'
      end
      update!(charge_usd: known ? cost : charge_usd, status: outcome, upstream_id: upstream_id)
    end
  end

  private

  def byok_total(fee, details)
    upstream = details['upstream_inference_cost'] if details.is_a?(Hash)
    return nil unless upstream.is_a?(Numeric) && fee&.finite? && fee >= 0
    upstream = BigDecimal(upstream.to_s, exception: false)
    return nil unless upstream&.finite? && upstream >= 0
    fee + upstream
  end

end
