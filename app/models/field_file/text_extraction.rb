# A text file's own words, kept on the row so Field search can find them
# (the search_vector column reads extracted_text). Only plain-text formats
# are read, up to MAX_BYTES; PDFs and office documents are not extracted.
# Extraction runs once, after the file is saved, in FieldFiles::ExtractTextJob.
module FieldFile::TextExtraction

  extend ActiveSupport::Concern

  MAX_BYTES = 2.megabytes
  TEXT_EXTENSIONS = %w[txt text md markdown csv tsv json jsonl srt vtt yaml yml xml log org rst tex].freeze
  TEXT_CONTENT_TYPES = %w[application/json application/xml application/x-yaml application/yaml application/x-subrip].freeze

  included do
    after_create_commit -> { FieldFiles::ExtractTextJob.perform_later(id) }, if: :text_extractable?
  end

  def text_extractable?
    return false unless file.attached? && file.byte_size.to_i <= MAX_BYTES

    type = file.content_type.to_s
    extension = File.extname(file.filename.to_s).delete_prefix(".").downcase
    type.start_with?("text/") || TEXT_CONTENT_TYPES.include?(type) || TEXT_EXTENSIONS.include?(extension)
  end

  # Reads the bytes as UTF-8 (invalid sequences replaced, NULs dropped, since
  # Postgres text can't hold them) and stores them. update_columns: this is
  # derived data, not an edit, so updated_at and broadcasts stay as they were.
  def extract_text!
    return false unless kept? && text_extractable?

    text = file.download.dup.force_encoding(Encoding::UTF_8).scrub("�").delete("\u0000")
    text = text.delete_prefix("﻿")
    update_columns(extracted_text: text, text_extracted_at: Time.current)
    # Not an edit, so no updated_at; but an open search on the Field page
    # should refresh now that the file's words are searchable.
    broadcast_refresh
    true
  end

end
