# A recording can arrive with its transcript already written (the archive of
# transcripts made before the Field existed), and with where it came from.
class AddSuppliedTranscriptsToFieldRecordings < ActiveRecord::Migration[8.1]

  def change
    add_column :field_recordings, :transcript_source, :string, null: false, default: "vendor"
    add_column :field_recordings, :transcript_turns, :jsonb
    add_column :field_recordings, :source_path, :string, limit: 1000
    add_column :field_recordings, :recorded_at, :datetime
    add_column :field_recordings, :import_key, :string, limit: 200
    # Across every row, deleted ones included: a rerun of an import must not
    # bring back what someone removed.
    add_index :field_recordings, %i[account_id import_key], unique: true, where: "import_key IS NOT NULL"
  end

end
