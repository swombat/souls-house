# Recordings slice B (spec §8): one "suggested from what's said" label per
# unnamed speaker, with the quoted line that supports it. A suggestion is
# never a name: it renders beside the speaker until a human confirms it.
class AddSuggestionsToFieldRecordingSpeakers < ActiveRecord::Migration[8.1]

  def change
    add_reference :field_recording_speakers, :suggested_voice, foreign_key: { to_table: :field_voices, on_delete: :nullify }
    add_column :field_recording_speakers, :suggested_name, :string, limit: 100
    add_column :field_recording_speakers, :suggestion_quote, :string, limit: 300
    add_column :field_recording_speakers, :suggestion_quote_ms, :bigint
    add_column :field_recording_speakers, :suggestion_source, :string
    add_column :field_recording_speakers, :suggested_at, :datetime
    # Every human decision about a speaker (name, un-name, dismiss) moves this
    # on. A suggestion records the value it was made against; a late inference
    # or a stale chip whose value no longer matches is refused.
    add_column :field_recording_speakers, :decision_generation, :integer, null: false, default: 0
    add_column :field_recording_speakers, :suggestion_generation, :integer
    # One suggestion call per recording, claimed durably before it is made.
    add_column :field_recordings, :suggestions_state, :string
  end

end
