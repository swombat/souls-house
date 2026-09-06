class AddJournalEntryStatsToAgents < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :journal_entry_stats, :jsonb, null: false, default: {}
    add_column :agents, :journal_stats_requested_at, :datetime
  end

end
