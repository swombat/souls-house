module Message::Replayable

  extend ActiveSupport::Concern

  # Historical metadata remains readable; Rails no longer replays provider turns.
  REASONING_SKIP_REASONS = {
    "legacy_no_signature" => "Thinking unavailable: this turn was created before signed thinking blocks were stored.",
    "tool_continuity_missing" => "Thinking degraded: an earlier tool call is missing continuity metadata.",
    "provider_unsupported" => "Thinking unavailable for this turn.",
    "anthropic_key_unavailable" => "Thinking unavailable: Anthropic API key not configured."
  }.freeze

  def reasoning_skip_reason
    self[:reasoning_skip_reason] || inferred_skip_reason
  end

  def reasoning_skip_reason_label
    REASONING_SKIP_REASONS[reasoning_skip_reason]
  end

  def thinking_signature
    replay_payload&.dig("thinking", "signature")
  end

  private

  def inferred_skip_reason
    "legacy_no_signature" if role == "assistant" && thinking_text.present? && replay_payload.blank?
  end

end
