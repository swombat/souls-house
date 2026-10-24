class CreatePendingWakes < ActiveRecord::Migration[8.1]

  # A trigger that arrived while its resident was already responding in that
  # room. One open row per resident per room: later knocks coalesce into it.
  # It is released (one follow-up run) when the busy run finishes, or dropped
  # with a reason. The row is bookkeeping for a room and a resident, so it
  # goes with either; it outlives the run it released.
  def change
    create_table :pending_wakes do |t|
      t.references :chat, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.string :requested_by, null: false
      t.integer :requests_count, null: false, default: 1
      t.datetime :first_requested_at, null: false
      t.datetime :last_requested_at, null: false
      t.datetime :released_at
      t.datetime :dropped_at
      t.string :drop_reason
      t.references :released_interaction, foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify }
      t.timestamps
    end
    add_index :pending_wakes, [ :chat_id, :agent_id ], unique: true,
              where: "released_at IS NULL AND dropped_at IS NULL", name: "index_pending_wakes_one_open_per_resident_room"

    # What asked for the wake. A wake stands while at least one of its
    # sources does: a message not discarded whose author is still a member, or
    # a trigger whose requester (person or resident) still has their place.
    # Checked at release and again when the released run claims.
    create_table :pending_wake_sources do |t|
      t.references :pending_wake, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.references :message, foreign_key: { on_delete: :cascade }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :requester_agent, foreign_key: { to_table: :agents, on_delete: :nullify }
      t.timestamps
    end
  end

end
