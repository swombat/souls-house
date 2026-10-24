# Transcribes a PDF's scanned pages once its own text has been read
# (FieldFile::PdfOcr). Queued by FieldFile::PdfExtraction only for files
# brought in after Field OCR was turned on. There is no backfill: the Field
# already holding scans is not sent anywhere by this.
module FieldFiles
  class OcrPdfJob < ApplicationJob

    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(field_file_id)
      FieldFile.find(field_file_id).transcribe_pdf!
    end

  end
end
