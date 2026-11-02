# Commitments (#699 slice B, YNwRqe): a resident's one-shot promise to come
# back to something at a time. A minute sweep activates a due row once: a
# house message in the source conversation (or a new one in a chosen room)
# and a wake for the resident. Activation is not completion.
class CreateCommitments < ActiveRecord::Migration[8.1]

  def change
    create_table :commitments do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_chat, null: false, foreign_key: { to_table: :chats, on_delete: :cascade }
      t.references :source_message, foreign_key: { to_table: :messages, on_delete: :nullify }
      t.text :text, null: false
      # Normalised text (trimmed, whitespace collapsed, case folded), hashed:
      # the identity "the same commitment" is checked on.
      t.string :text_digest, null: false
      t.datetime :due_at, null: false
      t.string :destination, null: false, default: "same_conversation"
      t.references :room, foreign_key: { on_delete: :nullify }
      t.string :status, null: false, default: "scheduled"
      # Tried but could not activate yet (paused, out of the room, ...): the
      # row stays scheduled and the sweep tries again.
      t.datetime :last_attempted_at
      t.string :waiting_reason
      t.datetime :activated_at
      t.references :activation_chat, foreign_key: { to_table: :chats, on_delete: :nullify }
      t.references :activation_message, foreign_key: { to_table: :messages, on_delete: :nullify }
      # Custody of the wake after the message is posted (Commitment#sync_wake!):
      # woken (a run reserved, carrying the commitment as its cue), held (a
      # PendingWake), retrying (lost or refused for now; wake_reason says
      # why), delivered (the run carrying the cue ended ok), or blocked (not
      # retried; wake_reason says why), or withdrawn (cancelled while in custody).
      t.string :wake_state
      t.string :wake_reason
      t.references :wake_interaction, foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify }
      t.references :pending_wake, foreign_key: { on_delete: :nullify }
      # This commitment's own source on that wake, withdrawn on cancel so a
      # wake shared with others keeps their requests.
      t.references :pending_wake_source, foreign_key: { on_delete: :nullify }
      t.integer :wake_runs, null: false, default: 0 # runs started for this wake
      t.datetime :last_wake_at
      t.datetime :delivered_at
      t.datetime :cancelled_at
      t.references :cancelled_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :cancelled_by_agent, foreign_key: { to_table: :agents, on_delete: :nullify }
      t.integer :reschedule_count, null: false, default: 0
      t.timestamps
    end

    add_index :commitments, [ :status, :due_at ]
    add_index :commitments, :wake_state, where: "wake_state IN ('woken', 'held', 'retrying')",
              name: "idx_commitments_wake_in_custody"
    add_index :commitments, [ :agent_id, :text_digest ], unique: true, where: "status = 'scheduled'",
              name: "idx_commitments_one_scheduled_per_text"
    add_check_constraint :commitments, "status IN ('scheduled', 'activated', 'cancelled')", name: "commitments_status"
    add_check_constraint :commitments, "destination IN ('same_conversation', 'new_conversation')",
                         name: "commitments_destination"
  end

end
