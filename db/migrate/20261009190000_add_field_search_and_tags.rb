# Search and tags for the Field (conversation beQOmJ).
#
# Search: a stored tsvector on each of the three item kinds, built with the
# `simple` configuration (no stemming, so English and Spanish behave the same)
# and weighted title > note > body. Generated columns keep it in step with the
# row without callbacks.
#
# A tsvector can't exceed 1 MB (1,048,575 bytes), and a generated column that
# would exceed it makes the row's own INSERT or UPDATE fail (a transcript
# becoming ready, a note being saved). So the input is bounded in BYTES, which
# is what the vector's size follows, not characters (a 4-byte character costs
# four times a 1-byte one; Mira's 180,000-character repro made 1.2 MB).
#
# Budget: 7 bytes of vector per input byte. Measured worst (PG 17, simple
# config): 4.04 for distinct hyphenated ASCII (`a1-b1`), 3.58 for Mira's
# 4-byte alphabetic compounds, under 3.2 for the rest we built. Why it's
# bounded at all: a lexeme costs its own bytes plus at most 9 bytes of entry
# and position overhead, hyphenated compounds emit at most ~0.75 lexemes per
# input byte, and the whole word plus its parts at most double the lexeme bytes.
#
# Title: TITLE_CHARS characters (at most 4 bytes each). Note: NOTE_CHARS
# characters. Body: at most BODY_BYTES bytes, cut at a whole character by
# `byte_bounded` below. Total at most 4,000 + 16,000 + 128,000 = 148,000
# bytes; times 7 is 1,036,000. The cost: a body is searched only up to its
# first 128 kB (4 of 842 transcripts in the archive this was built for).
#
# Tags: account-scoped names, many per item, any item kind. Deleting a tag
# and removing a tag from an item both discard (project rule), so who did
# what stays on the row.
class AddFieldSearchAndTags < ActiveRecord::Migration[8.1]

  TITLE_CHARS = 1_000 # title (twice, see `split_names`) and, for files, the filename
  NOTE_CHARS = 4_000
  BODY_BYTES = 128_000

  def change
    add_column :field_files, :extracted_text, :text
    add_column :field_files, :text_extracted_at, :datetime
    # The uploaded file's name, so a file titled "Receipt" is still found by
    # "orchid-invoice". Kept in step by FieldFile; backfilled here.
    add_column :field_files, :indexed_filename, :string
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE field_files SET indexed_filename = blobs.filename
          FROM active_storage_attachments attachments
          JOIN active_storage_blobs blobs ON blobs.id = attachments.blob_id
          WHERE attachments.record_type = 'FieldFile' AND attachments.name = 'file'
            AND attachments.record_id = field_files.id
        SQL
      end
    end

    # A transcript is searchable only once the recording is ready, whatever
    # else ever writes transcript_text.
    add_search_vector :field_recordings, title: split_names("coalesce(title, '')"), note: "note",
      body: "CASE WHEN status = 'ready' THEN transcript_text END"
    add_search_vector :field_files, title: split_names("coalesce(title, '') || ' ' || coalesce(indexed_filename, '')"),
      note: "note", body: "extracted_text"
    add_search_vector :whiteboards, title: split_names("coalesce(name, '')"), note: "summary", body: "content"

    create_table :field_tags do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false, limit: 50
      t.references :created_by, polymorphic: true
      t.datetime :discarded_at
      t.references :discarded_by, polymorphic: true
      t.timestamps

      t.index %i[account_id name], unique: true, where: "discarded_at IS NULL", name: "index_field_tags_on_account_and_kept_name"
    end

    create_table :field_taggings do |t|
      t.references :account, null: false, foreign_key: true
      t.references :field_tag, null: false, foreign_key: true
      t.references :taggable, polymorphic: true, null: false
      t.references :tagged_by, polymorphic: true
      t.datetime :discarded_at
      t.references :discarded_by, polymorphic: true
      t.timestamps

      t.index %i[field_tag_id taggable_type taggable_id], unique: true, where: "discarded_at IS NULL",
        name: "index_field_taggings_on_kept_tag_and_item"
      t.check_constraint "taggable_type IN ('FieldFile', 'FieldRecording', 'Whiteboard')", name: "field_taggings_taggable_type"
    end
  end

  private

  # The longest prefix from a ladder of character cuts that fits in `bytes`.
  # Generated columns need immutable functions, which rules out byte slicing
  # through convert_to; left() and octet_length() are immutable. The last
  # rung, bytes / 4 characters, always fits because a character is at most 4
  # bytes, so the result never exceeds `bytes`.
  def byte_bounded(expression, bytes)
    rungs = [ 1.0, 0.95, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.33 ].map { |share| (bytes * share).to_i }
    cases = rungs.map { |chars| "WHEN octet_length(left(#{expression}, #{chars})) <= #{bytes} THEN left(#{expression}, #{chars})" }
    "(CASE #{cases.join(" ")} ELSE left(#{expression}, #{bytes / 4}) END)"
  end

  # Postgres reads "orchid-invoice.txt" or "2024-11-02 board.md" as single
  # file tokens, so "orchid" or "board" would never match a name. Titles often
  # are filenames (they default to one), so names are indexed twice: as
  # written (so "node.js" still matches itself) and with . _ - / as spaces.
  def split_names(expression)
    # repeat(), not a literal: the expression is squished, which would
    # collapse a run of spaces and turn the mapping into a deletion.
    "#{expression} || ' ' || translate(#{expression}, '._-/', repeat(' ', 4))"
  end

  def add_search_vector(table, title:, note:, body:)
    expression = <<~SQL.squish
      setweight(to_tsvector('simple'::regconfig, left(coalesce(#{title}, ''), #{TITLE_CHARS})), 'A') ||
      setweight(to_tsvector('simple'::regconfig, left(coalesce(#{note}, ''), #{NOTE_CHARS})), 'B') ||
      setweight(to_tsvector('simple'::regconfig, #{byte_bounded("coalesce(#{body}, '')", BODY_BYTES)}), 'C')
    SQL
    add_column table, :search_vector, :virtual, type: :tsvector, as: expression, stored: true
    add_index table, :search_vector, using: :gin
  end

end
