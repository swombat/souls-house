class CreateStones < ActiveRecord::Migration[8.1]

  def change
    create_table :stones do |t|
      t.references :chat, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :withdrawn_at
      t.string :public_token, null: false
      t.timestamps
    end
    add_index :stones, :public_token, unique: true

    create_table :stone_revisions do |t|
      t.references :stone, null: false, foreign_key: { on_delete: :cascade }
      t.integer :number, null: false
      t.string :title, null: false
      t.references :user, foreign_key: true
      t.references :agent, foreign_key: true
      t.string :policy_version, null: false
      t.string :preview_status, null: false, default: "not_requested"
      t.text :preview_error
      t.timestamps
    end
    add_index :stone_revisions, [ :stone_id, :number ], unique: true
    add_check_constraint :stone_revisions, "(user_id IS NULL) <> (agent_id IS NULL)", name: "stone_revisions_one_author"
    add_check_constraint :stone_revisions, "number > 0", name: "stone_revisions_positive_number"

    create_table :message_stone_revisions do |t|
      t.references :message, null: false, foreign_key: { on_delete: :cascade }
      t.references :stone_revision, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :message_stone_revisions, [ :message_id, :stone_revision_id ], unique: true
  end

end
