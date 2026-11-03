class KimiCodeNotice

  # Auth failures do not prove which kind of key was supplied. Never echo a
  # provider body (which may contain secrets) or offer OAuth reconnection.
  def self.text(error_kind)
    case error_kind
    when "auth_expired"
      "Kimi Code rejected the credential. Add a valid Kimi Code Console subscription key in Account settings → Agent API keys; a standard Moonshot platform (PAYG) key cannot be used here."
    when "subscription_limit"
      "Kimi Code reported a rate or subscription limit. Check your allowance in the Kimi Code Console and retry later; no OpenRouter fallback was used."
    when "model_unavailable"
      "The selected Kimi Code model is unavailable on this plan. Check model access in the Kimi Code Console or explicitly choose another model."
    end
  end

end
