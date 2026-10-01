class CreateReplyExpectations < ActiveRecord::Migration[8.1]

  def change
    # Existing messages stay untouched. Only new conversational activity queues work.
    add_column :messages, :reply_attention_pending, :boolean, default: false, null: false
    add_index :messages, [ :chat_id, :id ], where: "reply_attention_pending", name: "index_messages_pending_reply_attention"

    create_table :reply_expectations do |t|
      t.references :message, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.references :answered_by_message, foreign_key: { to_table: :messages, on_delete: :nullify }
      t.integer :state, default: 0, null: false
      t.float :score, null: false
      t.string :classifier_version, null: false
      t.timestamps
    end
    add_index :reply_expectations, [ :message_id, :user_id ], unique: true
    add_index :reply_expectations, :user_id, where: "state = 0", name: "index_open_reply_expectations_on_user"
    add_check_constraint :reply_expectations, "state IN (0, 1, 2)", name: "reply_expectation_state"

    create_table :reply_dismissals do |t|
      t.references :chat, null: false, foreign_key: { on_delete: :cascade }
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :through_message_id, null: false
      t.timestamps
    end
    # A cutoff survives removal of its source message; it is not an association.
    add_index :reply_dismissals, [ :chat_id, :user_id ], unique: true
  end

end
