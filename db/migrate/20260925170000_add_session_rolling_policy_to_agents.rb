class AddSessionRollingPolicyToAgents < ActiveRecord::Migration[8.1]

  # Bound persistent Chaos sessions the way a reaped CLI process is bounded:
  # roll to a fresh session after idle time, total age, or a context budget.
  # Zero disables a check.
  def change
    add_column :agents, :session_idle_timeout_minutes, :integer, default: 45, null: false
    add_column :agents, :session_max_age_minutes, :integer, default: 240, null: false
    add_column :agents, :session_context_budget_tokens, :integer, default: 300_000, null: false
  end

end
