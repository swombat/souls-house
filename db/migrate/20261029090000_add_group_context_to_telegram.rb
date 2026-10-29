# #596 follow-up: an enabled group keeps every message as context, and only
# the ones addressed to the bot wake the resident. Rows before this were all
# addressed (nothing else was kept). The agent column records what getMe
# says about BotFather's privacy mode, so settings can say when Telegram is
# still withholding the group's untagged messages.
class AddGroupContextToTelegram < ActiveRecord::Migration[8.1]

  def change
    add_column :telegram_messages, :addressed, :boolean, default: true, null: false
    add_column :agents, :telegram_reads_all_group_messages, :boolean
  end

end
