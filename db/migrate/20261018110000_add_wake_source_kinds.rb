class AddWakeSourceKinds < ActiveRecord::Migration[8.1]

  def change
    # No backfill: a label or nearby message cannot establish who asked.
    add_column :agent_runtime_interactions, :wake_source_kinds, :jsonb, default: [], null: false
    add_column :pending_wake_sources, :wake_source_kinds, :jsonb, default: [], null: false
  end

end
