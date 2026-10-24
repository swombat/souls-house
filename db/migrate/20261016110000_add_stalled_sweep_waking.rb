class AddStalledSweepWaking < ActiveRecord::Migration[8.1]

  def change
    # Off by default: with the interval on and this off, the sweeper only
    # records (shadow). On, it may wake a resident it judges has a step.
    add_column :settings, :stalled_sweep_wake, :boolean, null: false, default: false

    # The last message from a person when the sweep ran: the chain a wake
    # belongs to. One wake per resident per chain; only a person's message
    # starts a new one.
    add_column :stalled_thread_sweeps, :human_message_id, :bigint
    # The residents scored over the threshold, by id, in the snapshot's seat
    # order: what a wake targets (names are not unique).
    add_column :stalled_thread_sweeps, :would_wake_agent_ids, :jsonb, null: false, default: []
    add_column :stalled_thread_sweeps, :woken_agent_ids, :jsonb, null: false, default: []
    # [{ agent_id:, name:, reason: }] for each scored resident not woken.
    add_column :stalled_thread_sweeps, :held, :jsonb, null: false, default: []
    add_column :stalled_thread_sweeps, :stopped, :boolean, null: false, default: false
    add_index :stalled_thread_sweeps, [ :chat_id, :human_message_id ]

    add_reference :agent_runtime_interactions, :stalled_thread_sweep, foreign_key: { on_delete: :nullify }
  end

end
