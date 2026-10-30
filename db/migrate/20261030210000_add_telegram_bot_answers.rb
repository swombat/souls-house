class AddTelegramBotAnswers < ActiveRecord::Migration[8.1]

  def change
    add_column :telegram_subscriptions, :answers_bots, :boolean, default: false, null: false
    add_column :telegram_subscriptions, :answer_bot_usernames, :string, array: true, default: [], null: false
    add_column :telegram_subscriptions, :bot_wake_streak, :integer, default: 0, null: false
    add_column :telegram_subscriptions, :bot_cap_notice_message_id, :bigint
    add_check_constraint :telegram_subscriptions, "bot_wake_streak BETWEEN 0 AND 3",
      name: "telegram_subscriptions_bot_wake_streak"
  end

end
