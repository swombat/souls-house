# The account's transcription glossary: words Scribe should be biased towards
# (keyterms). Removal leaves a tombstone (suppressed_at) so automation can't
# put a removed word back.
class CreateTranscriptionGlossaryTerms < ActiveRecord::Migration[8.1]

  def change
    create_table :transcription_glossary_terms do |t|
      t.references :account, null: false, foreign_key: true
      t.string :term, null: false
      t.string :normalized_term, null: false
      t.string :source, null: false, default: "manual"
      t.boolean :pinned, null: false, default: false
      t.datetime :suppressed_at
      t.integer :sightings_count, null: false, default: 0
      t.datetime :last_seen_at
      t.references :created_by_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :created_by_agent, foreign_key: { to_table: :agents, on_delete: :nullify }
      t.timestamps

      t.index %i[account_id normalized_term], unique: true
      t.check_constraint "source IN ('manual', 'correction', 'harvested')", name: "transcription_glossary_terms_source"
    end

    add_column :settings, :transcription_keyterms_enabled, :boolean, default: false, null: false
  end

end
