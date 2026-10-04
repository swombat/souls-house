class AddResidentRhythmCreators < ActiveRecord::Migration[8.1]

  def change
    change_column_null :rhythms, :creator_id, true
    remove_foreign_key :rhythms, :users, column: :creator_id
    add_foreign_key :rhythms, :users, column: :creator_id, on_delete: :nullify
    add_reference :rhythms, :creator_agent, foreign_key: { to_table: :agents, on_delete: :nullify }
    add_reference :rhythm_occurrences, :creator_agent, foreign_key: { to_table: :agents, on_delete: :nullify }
    add_check_constraint :rhythms, "creator_id IS NULL OR creator_agent_id IS NULL",
      name: "rhythms_one_creator"
    add_check_constraint :rhythm_occurrences, "creator_id IS NULL OR creator_agent_id IS NULL",
      name: "rhythm_occurrences_one_creator"

    # Resident invitations use the same durable dispatch, without attributing
    # their wake to the human who issued the resident's API key.
    change_column_null :message_dispatches, :user_id, true
    add_check_constraint :message_dispatches, "user_id IS NOT NULL OR kind = 'rhythm'",
      name: "message_dispatches_human_author"
  end

end
