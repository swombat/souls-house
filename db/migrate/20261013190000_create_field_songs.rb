class CreateFieldSongs < ActiveRecord::Migration[8.1]

  def change
    # A song shared in an account's Field: where to hear it (links and/or an
    # audio file), its words, why it was shared and for whom.
    create_table :field_songs do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :added_by, polymorphic: true
      t.references :shared_for, polymorphic: true
      t.string :title, null: false, limit: 200
      t.string :artist, limit: 200
      t.string :album, limit: 200
      t.integer :year
      # [{ provider, url, embed_id }], at most four, normalised on save.
      t.jsonb :links, null: false, default: []
      t.text :lyrics
      # Said on purpose: a song with no words, so it doesn't wait for lyrics.
      t.boolean :instrumental, null: false, default: false
      t.text :note
      t.integer :duration_ms
      t.datetime :dated_at
      t.datetime :discarded_at
      t.timestamps
    end
    add_index :field_songs, [ :account_id, :created_at ]
    add_index :field_songs, :discarded_at
    add_check_constraint :field_songs, "year IS NULL OR (year BETWEEN 1000 AND 3000)", name: "field_songs_year"
    add_check_constraint :field_songs, "NOT (instrumental AND lyrics ~ '[^[:space:]]')", name: "field_songs_instrumental_without_lyrics"
    add_column :field_songs, :search_vector, :virtual, type: :tsvector, stored: true, as: <<~SQL.squish
      setweight(to_tsvector('simple'::regconfig, coalesce(title, '') || ' ' || coalesce(artist, '')), 'A') ||
      setweight(to_tsvector('simple'::regconfig, coalesce(album, '') || ' ' || left(coalesce(note, ''), 4000)), 'B') ||
      setweight(to_tsvector('simple'::regconfig, left(coalesce(lyrics, ''), 40000)), 'C')
    SQL
    add_index :field_songs, :search_vector, using: :gin

    # Songs carry tags like every other Field item.
    reversible do |direction|
      direction.up do
        remove_check_constraint :field_taggings, name: "field_taggings_taggable_type"
        add_check_constraint :field_taggings, "taggable_type IN ('FieldFile', 'FieldRecording', 'Whiteboard', 'FieldTweet', 'FieldSong')", name: "field_taggings_taggable_type"
      end
      direction.down do
        remove_check_constraint :field_taggings, name: "field_taggings_taggable_type"
        add_check_constraint :field_taggings, "taggable_type IN ('FieldFile', 'FieldRecording', 'Whiteboard', 'FieldTweet')", name: "field_taggings_taggable_type"
      end
    end
  end

end
