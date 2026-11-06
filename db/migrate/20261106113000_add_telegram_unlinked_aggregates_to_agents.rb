class AddTelegramUnlinkedAggregatesToAgents < ActiveRecord::Migration[8.0]

  def change
    add_column :agents, :telegram_unlinked_messages_count, :bigint, default: 0, null: false
    add_column :agents, :telegram_unlinked_last_received_at, :datetime
  end

end
