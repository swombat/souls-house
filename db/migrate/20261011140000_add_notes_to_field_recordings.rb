# A meeting's notes (summary, action items: 5–80 KB in the PA archive) kept
# inside its recording rather than as a separate Field item (conversation
# WjNZVj). `note` stays the short "why I'm bringing this" (2,000 chars);
# `notes` is Markdown up to 100,000 characters, like a note's content.
#
# Search: the vector is a generated column with a byte budget (see
# 20261009190000_add_field_search_and_tags.rb: title 4,000 + note 16,000 +
# body 128,000 bytes, times 7, just under the 1 MB tsvector cap), which
# leaves no room for a fourth part. So notes go at the front of the body:
# notes, then the transcript (once ready), together bounded at 128,000 bytes.
# The limitation, exactly: notes are capped in characters and the body in
# bytes, so notes take as much of the 128 kB as they need, the transcript
# gets what is left, and notes past 128 kB of their own (possible with
# multi-byte text: 100,000 characters can be up to 400 kB) lose their own
# tail and leave none of the transcript in search. A recording without notes
# indexes exactly as before (its body is the old expression, no separator).
#
# The helpers are copied from that migration (a migration must not depend on
# another's code). `||` rather than concat_ws: a generated column needs
# immutable functions, and concat_ws is only stable.
class AddNotesToFieldRecordings < ActiveRecord::Migration[8.1]

  TITLE_CHARS = 1_000
  NOTE_CHARS = 4_000
  BODY_BYTES = 128_000

  TRANSCRIPT = "CASE WHEN status = 'ready' THEN transcript_text END"

  def up
    add_column :field_recordings, :notes, :text
    replace_search_vector(body: "CASE WHEN coalesce(notes, '') = '' THEN #{TRANSCRIPT} ELSE notes || ' ' || coalesce(#{TRANSCRIPT}, '') END")
  end

  def down
    replace_search_vector(body: TRANSCRIPT)
    remove_column :field_recordings, :notes
  end

  private

  def replace_search_vector(body:)
    remove_index :field_recordings, :search_vector
    remove_column :field_recordings, :search_vector

    title = split_names("coalesce(title, '')")
    expression = <<~SQL.squish
      setweight(to_tsvector('simple'::regconfig, left(coalesce(#{title}, ''), #{TITLE_CHARS})), 'A') ||
      setweight(to_tsvector('simple'::regconfig, left(coalesce(note, ''), #{NOTE_CHARS})), 'B') ||
      setweight(to_tsvector('simple'::regconfig, #{byte_bounded("coalesce(#{body}, '')", BODY_BYTES)}), 'C')
    SQL
    add_column :field_recordings, :search_vector, :virtual, type: :tsvector, as: expression, stored: true
    add_index :field_recordings, :search_vector, using: :gin
  end

  def byte_bounded(expression, bytes)
    rungs = [ 1.0, 0.95, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.33 ].map { |share| (bytes * share).to_i }
    cases = rungs.map { |chars| "WHEN octet_length(left(#{expression}, #{chars})) <= #{bytes} THEN left(#{expression}, #{chars})" }
    "(CASE #{cases.join(" ")} ELSE left(#{expression}, #{bytes / 4}) END)"
  end

  def split_names(expression)
    "#{expression} || ' ' || translate(#{expression}, '._-/', repeat(' ', 4))"
  end

end
