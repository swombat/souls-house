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
  def change
    add_column :settings, :paid_fallback_enabled, :boolean, null: false, default: false
    add_column :chat_agents, :runtime_freshness_generation, :integer, null: false, default: 0
  end

end
