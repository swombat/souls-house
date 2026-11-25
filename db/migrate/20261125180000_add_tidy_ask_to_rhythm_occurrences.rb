# The once-per-run question to a multi-resident rhythm run's last finisher
# (RhythmTidy, elRvNJ): when it was settled, and the run that carries it.
class AddTidyAskToRhythmOccurrences < ActiveRecord::Migration[8.1]

  def change
    add_column :rhythm_occurrences, :tidy_asked_at, :datetime
    add_reference :rhythm_occurrences, :tidy_interaction,
      foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify },
      index: { unique: true }
  end

end
