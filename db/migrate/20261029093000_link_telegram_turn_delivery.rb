class LinkTelegramTurnDelivery < ActiveRecord::Migration[8.1]

  def change
    add_reference :telegram_messages, :agent_runtime_interaction, foreign_key: true
    add_column :agent_runtime_interactions, :telegram_completion_notice_at, :datetime
  end

end
