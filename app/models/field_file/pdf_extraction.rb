# A PDF's own text, read page by page with Poppler (PdfText) so residents can
# read it and Field search and summaries cover it. Only the text layer the PDF
# already carries is read here; nothing is sent anywhere, and a scanned page
# comes out `empty` (a page without a text layer).
#
# pdf_status, for a PDF:
#
#   pending     waiting for FieldFiles::ExtractPdfJob
#   extracted   every page was read (some may be empty)
#   partial     some pages failed or were skipped by a limit (pdf_status_reason)
#   failed      the file could not be read at all (pdf_status_reason)
#   encrypted   the PDF needs a password to open; nothing is read
#
# The pages' text, joined, is also kept in extracted_text (cut to
# MAX_JOINED_BYTES), which is what Field search and summaries read.
module FieldFile::PdfExtraction

  extend ActiveSupport::Concern

  STATUSES = %w[pending extracted partial failed encrypted].freeze
  # Pages past this are not read.
  MAX_PAGES = 500
  # The whole read stops after this long; pages not reached are skipped.
  TIME_BUDGET = 5.minutes
  MAX_JOINED_BYTES = FieldFile::TextExtraction::MAX_BYTES
  PAGE_SEPARATOR = "\n\n"

  included do
    has_many :pages, -> { in_order }, class_name: "FieldFilePage", dependent: :delete_all

    validates :pdf_status, inclusion: { in: STATUSES }, allow_nil: true

    before_create { self.pdf_status = "pending" if pdf? }
    after_create_commit -> { FieldFiles::ExtractPdfJob.perform_later(id) }, if: :pdf?
  end

  def pdf?
    return false unless file.attached?

    file.content_type.to_s == "application/pdf" || File.extname(file.filename.to_s).casecmp?(".pdf")
  end

  def pdf_readable? = pdf_status.in?(%w[extracted partial])

  # Reads the file and stores what came out. Safe to run again: the pages are
  # replaced as a whole. update_columns, as for text files: derived data, not
  # an edit.
  def extract_pdf!(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    return false unless kept? && pdf?

    result = file.open { |tempfile| read_pdf(tempfile.path, clock) }
    store_pdf_result(result)
    broadcast_refresh
    enqueue_summary
    true
  end

  def pdf_extraction_json
    return nil unless pdf_status

    coverage = pdf_coverage || {}
    {
      status: pdf_status,
      reason: pdf_status_reason,
      page_count: pdf_page_count,
      pages_with_text: coverage["text"].to_i,
      pages_without_text: coverage["empty"].to_i,
      pages_failed: coverage["failed"].to_i,
      pages_skipped: coverage["skipped"].to_i,
      text_source: "native"
    }
  end

  private

  def read_pdf(path, clock)
    info = PdfText.info(path)
    started = clock.call
    readable = [ info[:pages], MAX_PAGES ].min
    pages = {}

    (1..readable).each_slice(PdfText::BATCH_PAGES) do |numbers|
      if clock.call - started > TIME_BUDGET
        numbers.each { |n| pages[n] = page_row(n, "skipped", reason: "Reading the file took too long") }
        next
      end
      read_batch(path, numbers).each { |row| pages[row[:page_number]] = row }
    end
    ((readable + 1)..info[:pages]).each do |n|
      pages[n] = page_row(n, "skipped", reason: "Only the first #{MAX_PAGES} pages are read")
    end

    { page_count: info[:pages], pages: pages.values }
  rescue PdfText::Encrypted => e
    { status: "encrypted", reason: e.message }
  rescue PdfText::Error => e
    { status: "failed", reason: e.message }
  end

  # One pdftotext run for the batch; if that fails, each page on its own so
  # one bad page doesn't lose the rest.
  def read_batch(path, numbers)
    PdfText.pages(path, numbers.first, numbers.last).each_with_index.map do |text, i|
      page_row(numbers.first + i, text.strip.empty? ? "empty" : "text", text: text)
    end
  rescue PdfText::CommandFailed
    numbers.map do |n|
      text = PdfText.page(path, n)
      page_row(n, text.strip.empty? ? "empty" : "text", text: text)
    rescue PdfText::CommandFailed => e
      page_row(n, "failed", reason: e.message)
    end
  end

  def page_row(number, status, text: nil, reason: nil)
    { page_number: number, native_status: status, native_text: (text if status == "text"), native_reason: reason&.truncate(500) }
  end

  def store_pdf_result(result)
    now = Time.current
    rows = Array(result[:pages]).sort_by { it[:page_number] }
    coverage = rows.group_by { it[:native_status] }.transform_values(&:size)
    status, reason = result[:status] ? [ result[:status], result[:reason] ] : outcome(coverage)

    with_lock do
      pages.delete_all
      FieldFilePage.insert_all(rows.map { it.merge(field_file_id: id, created_at: now, updated_at: now) }) if rows.any?
      update_columns(
        pdf_status: status, pdf_status_reason: reason&.truncate(500),
        pdf_page_count: result[:page_count], pdf_coverage: (coverage if rows.any?),
        extracted_text: joined_text(rows), text_extracted_at: now
      )
    end
  end

  def outcome(coverage)
    failed, skipped = coverage["failed"].to_i, coverage["skipped"].to_i
    return [ "extracted", nil ] if failed.zero? && skipped.zero?

    parts = []
    parts << "#{failed} #{"page".pluralize(failed)} could not be read" if failed.positive?
    parts << "#{skipped} #{"page".pluralize(skipped)} not read (a limit was reached)" if skipped.positive?
    [ "partial", parts.join("; ") ]
  end

  # The pages' text in order, for search and summaries, cut whole-page where
  # it can be and never mid-character.
  def joined_text(rows)
    joined = +""
    rows.each do |row|
      next if row[:native_text].blank?

      piece = joined.empty? ? row[:native_text] : PAGE_SEPARATOR + row[:native_text]
      if joined.bytesize + piece.bytesize > MAX_JOINED_BYTES
        joined << piece.byteslice(0, MAX_JOINED_BYTES - joined.bytesize).scrub("")
        break
      end
      joined << piece
    end
    joined
  end

end
