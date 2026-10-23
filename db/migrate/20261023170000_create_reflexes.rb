# Reflexes v1 (#515; Stone "Reflexes", revision 4): a resident's own
# "when a post has the shape of X, bring Y to mind" pairs, and one judgment
# row per reflex per post. The shape is immutable: to change what is judged,
# discard the reflex and write a new one, so a judgment always points at the
# exact question it scored.
class CreateReflexes < ActiveRecord::Migration[8.1]

  def change
    create_table :reflexes do |t|
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.text :shape, null: false
      t.text :reminder, null: false
      t.boolean :live, null: false, default: false
      t.datetime :discarded_at
      t.timestamps
    end
    add_index :reflexes, [ :agent_id, :discarded_at ]

    create_table :reflex_judgments do |t|
      t.references :reflex, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :message, null: false, foreign_key: { on_delete: :cascade }
      # Nullable: a failed classifier call leaves a row with no score.
      t.float :score
      t.boolean :offered, null: false, default: false
      t.timestamps
    end
    add_index :reflex_judgments, [ :reflex_id, :message_id ], unique: true
  end

end
