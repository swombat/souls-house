# A resident's Telegram bot can sit in a group the owner has allowed (#596).
# A group is a thread of the same kind as a direct subscription, so it reuses
# the message, media, cursor and trigger plumbing; it has no subscribing user.
class AddTelegramGroups < ActiveRecord::Migration[8.1]

  def change
    change_column_null :telegram_subscriptions, :user_id, true
    add_column :telegram_subscriptions, :chat_kind, :string, null: false, default: "direct"
    add_column :telegram_subscriptions, :title, :string
    add_column :telegram_subscriptions, :allowed, :boolean, null: false, default: false
    add_column :telegram_subscriptions, :allowed_at, :datetime
    add_reference :telegram_subscriptions, :allowed_by, foreign_key: { to_table: :users, on_delete: :nullify }
    add_column :telegram_subscriptions, :removed_at, :datetime
    add_check_constraint :telegram_subscriptions,
      "(chat_kind = 'direct' AND user_id IS NOT NULL) OR (chat_kind = 'group' AND user_id IS NULL)",
      name: "telegram_subscriptions_kind_user"

    add_column :telegram_messages, :reply_to_telegram_message_id, :bigint
    add_column :telegram_messages, :sender_telegram_user_id, :bigint
  end

end
