# Thresholds after which a persistent Chaos session is rolled to a fresh one.
# The runtime shim evaluates them against its session sidecar and reports the
# roll as idle-timeout, max-age, or context-budget. Zero disables a check.
module Agent::SessionPolicy

  extend ActiveSupport::Concern

  included do
    validates :session_idle_timeout_minutes, :session_max_age_minutes,
      numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 30.days.in_minutes.to_i }
    validates :session_context_budget_tokens,
      numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 2_000_000 }
  end

  def runtime_session_policy
    {
      idle_timeout_secs: session_idle_timeout_minutes.minutes.to_i,
      max_age_secs: session_max_age_minutes.minutes.to_i,
      context_budget_tokens: session_context_budget_tokens
    }
  end

end
