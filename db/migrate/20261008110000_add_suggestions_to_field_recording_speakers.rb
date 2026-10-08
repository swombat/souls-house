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
  end

end
