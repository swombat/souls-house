module HouseInference
  # What one OpenRouter call cost the house, from the response's `usage`:
  # BigDecimal dollars rounded up to 8 places, or nil when it can't be known.
  #
  # With BYOK (Daniel's choice, 2026-10-10: cheaper than OpenRouter's
  # margin), OpenRouter's `cost` is only its own fee and the provider bills
  # its key directly. That provider charge is reported per call as
  # cost_details.upstream_inference_cost, so the call costs the house the
  # sum. A BYOK call without a usable upstream cost can't be metered.
  module UsageCost

    module_function

    # => [cost or nil, byok?]
    def call(usage)
      return [ nil, false ] unless usage.is_a?(Hash)

      cost = BigDecimal(usage['cost'].to_s, exception: false)
      byok = usage['is_byok'] == true
      cost = byok_total(cost, usage['cost_details']) if byok
      known = cost&.finite? && cost >= 0
      [ (cost.ceil(8) if known), byok ]
    end

    def byok_total(fee, details)
      upstream = details['upstream_inference_cost'] if details.is_a?(Hash)
      return nil unless upstream.is_a?(Numeric) && fee&.finite? && fee >= 0

      upstream = BigDecimal(upstream.to_s, exception: false)
      return nil unless upstream&.finite? && upstream >= 0

      fee + upstream
    end

  end
end
