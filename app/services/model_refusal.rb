# Whether a run tagged error_kind "model_unavailable" carries evidence that
# the provider refused the model for the subscription it runs on (#1118,
# Mira's reviews of #1136). The runtime's tag can come from stdout alone,
# which can quote the conversation, while the run's recorded failure is
# something else entirely. So the claim stands only when the runtime's own
# failure text, the redacted runtime_failure the shim records from Chaos's
# error event or stderr, says the model isn't available on the plan, account
# or subscription. "Invalid model selection" or "not recognized" shows a
# rejection, not why, so it earns no subscription claim: such a run is the
# runtime error it was, and its Runs line quotes what the runtime said.
#
# SUBSCRIPTION is the plan/account/subscription branch of the model-refusal
# pattern in agent-runtime/trigger_shim.py (classify_provider_error); keep
# the two in step.
module ModelRefusal

  KIND = "model_unavailable".freeze
  SUBSCRIPTION = /model [^\n]{0,80}? (?:is )?not (?:available|supported) (?:for|on|in) (?:your|this) (?:plan|account|subscription)/i

  module_function

  def evidenced?(body)
    return false unless body.is_a?(Hash) && body["error_kind"] == KIND

    failure = body["runtime_failure"]
    message = failure["message"] if failure.is_a?(Hash)
    message.present? && SUBSCRIPTION.match?(message.to_s)
  end

  # The body's error_kind, except that an unevidenced model refusal is no kind
  # at all, so no notice names a cause the run doesn't show.
  def error_kind(body)
    return unless body.is_a?(Hash)

    kind = body["error_kind"]
    return if kind == KIND && !evidenced?(body)

    kind
  end

end
