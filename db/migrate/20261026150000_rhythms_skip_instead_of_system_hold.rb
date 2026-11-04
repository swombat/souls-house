# A rhythm that cannot fire safely now skips the slot and records why, instead
# of installing a system hold that only a click could release. Any open system
# hold is released first (production has never placed one), then the kind is
# retired: its partial index goes and a check keeps open holds to human and
# agent.
class RhythmsSkipInsteadOfSystemHold < ActiveRecord::Migration[8.1]

  def up
    add_column :rhythms, :last_skipped_at, :datetime
    add_column :rhythms, :last_skip_reason, :string

    execute <<~SQL
      UPDATE rhythm_holds SET released_at = NOW(), updated_at = NOW()
      WHERE kind = 'system' AND released_at IS NULL
    SQL
    remove_index :rhythm_holds, name: "index_rhythm_holds_one_open_system"
    # Released system holds stay as history; no new or open one can exist.
    add_check_constraint :rhythm_holds, "kind IN ('human', 'agent') OR released_at IS NOT NULL",
      name: "rhythm_holds_open_kind_known"
  end

  def down
    remove_check_constraint :rhythm_holds, name: "rhythm_holds_open_kind_known"
    add_index :rhythm_holds, %i[rhythm_id kind], name: "index_rhythm_holds_one_open_system", unique: true,
      where: "((released_at IS NULL) AND ((kind)::text = 'system'::text))"
    remove_column :rhythms, :last_skip_reason
    remove_column :rhythms, :last_skipped_at
  end

end
