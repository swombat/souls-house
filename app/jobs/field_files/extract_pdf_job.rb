# Reads a PDF's text layer page by page (FieldFile::PdfExtraction).
# `backfill` does it for PDFs brought in before this existed.
#
# Reading is local, but not everything after it is: each PDF that turns out
# to have text is queued for its summaries straight away, which sends that
# text, the title and the note to Claude Haiku through OpenRouter on the
# house's key (FieldSummaries, the existing summaries policy and disclosure).
# Running the backfill therefore sends every existing text PDF's text out
# for summarising. No page images are sent.
module FieldFiles
  class ExtractPdfJob < ApplicationJob

    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(field_file_id)
      FieldFile.find(field_file_id).extract_pdf!
    end

    def self.backfill
      FieldFile.kept.where(pdf_status: [ nil, "pending" ]).includes(file_attachment: :blob).find_each do |file|
        next unless file.pdf?

        file.update_column(:pdf_status, "pending") if file.pdf_status.nil?
        perform_later(file.id)
      end
    end

  end
end
