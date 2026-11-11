class AddPaidFallbackHop < ActiveRecord::Migration[8.1]

  # #690 slice B. The hop itself stays behind a Site Admin switch, off by
  # default, until slice C (the label and the owner notice) is live.
  #
  # runtime_freshness_generation: a resident in one conversation can run on
  # two Chaos sessions (its subscription lane and its paid-fallback lane). A
  # fresh start owed on one (a safeguard roll or a requested reset) must
  # reach the other too. Both lanes send this counter as the runtime's
  # runtime_session_generation, and the runtime rolls a session whose
  # sidecar recorded an older one. 0 is what every existing session already
  # recorded, so nothing rolls at deploy.
  #
  # A hop keeps one logical turn on one run (AgentRuntimeInteraction): every
  # link that follows a run's outcome (a commitment, the response chain, a
  # handoff, a released wake, the live card) follows the fallback's. On the
  # asynchronous path the subscription's refused ResidentTurn is retired as
  # hopped and the same run gets a second ResidentTurn, so "one turn per
  # run" becomes "one live turn per run". primary_result keeps the refused
  # attempt's response, so the run can still end with it if the hop can't go
  # ahead.
  def change
    add_column :settings, :paid_fallback_enabled, :boolean, null: false, default: false
    add_column :chat_agents, :runtime_freshness_generation, :integer, null: false, default: 0
    add_column :resident_turns, :hopped_at, :datetime
    remove_index :resident_turns, :agent_runtime_interaction_id, unique: true
    add_index :resident_turns, :agent_runtime_interaction_id, unique: true, where: "hopped_at IS NULL",
      name: "one_live_resident_turn_per_run"
    add_column :resident_fallback_turns, :primary_result, :jsonb
  end

end
