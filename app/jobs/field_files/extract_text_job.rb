# Reads a text file's words into the row so Field search covers them
# (FieldFile::TextExtraction). `backfill` does it for files brought in before
# extraction existed.
module FieldFiles
  class ExtractTextJob < ApplicationJob

    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(field_file_id)
      FieldFile.find(field_file_id).extract_text!
    end

    def self.backfill
      FieldFile.kept.where(text_extracted_at: nil).find_each do |file|
        perform_later(file.id) if file.text_extractable?
      end
    end

  end
end
