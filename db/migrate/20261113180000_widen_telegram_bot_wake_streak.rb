# The bot answer limit moved from a constant (3) to an account setting
# (Account#telegram_bot_wake_limit, 0..50), so the streak's ceiling widens to
# the highest limit an owner can choose.
class WidenTelegramBotWakeStreak < ActiveRecord::Migration[8.1]

  def up
    remove_check_constraint :telegram_subscriptions, name: "telegram_subscriptions_bot_wake_streak"
    add_check_constraint :telegram_subscriptions, "bot_wake_streak BETWEEN 0 AND 50",
      name: "telegram_subscriptions_bot_wake_streak"
  end

  def down
    execute "UPDATE telegram_subscriptions SET bot_wake_streak = 3 WHERE bot_wake_streak > 3"
    remove_check_constraint :telegram_subscriptions, name: "telegram_subscriptions_bot_wake_streak"
    add_check_constraint :telegram_subscriptions, "bot_wake_streak BETWEEN 0 AND 3",
      name: "telegram_subscriptions_bot_wake_streak"
  end

end
