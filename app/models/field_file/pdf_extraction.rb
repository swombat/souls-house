# A PDF's own text, read page by page with Imprimatur (PdfText) so residents can
# read it and Field search and summaries cover it. Only the text layer the PDF
# already carries is read here, inside the house; a scanned page comes out
# `empty` (a page without a text layer). Once a PDF has text it is summarised
# like any readable file (FieldSummarizable), which does send its text, title
# and note to the summary model.
#
# pdf_status, for a PDF:
#
#   pending     waiting for FieldFiles::ExtractPdfJob
#   extracted   every page was read whole (some may have no text layer)
#   partial     some pages failed, were skipped by a limit, or had their text
#               cut; pdf_status_reason says which
#   failed      the file could not be read at all (pdf_status_reason)
#   encrypted   the PDF needs a password to open; nothing is read
#
# Bounds: TIME_BUDGET for the whole read, every command included; rows only
# for the first MAX_PAGES pages (pages past it are counted in pdf_coverage,
# not stored); PdfText::MAX_PAGE_BYTES per page; MAX_JOINED_BYTES of joined
# text for search and summaries (pdf_coverage "search_text_truncated").
module FieldFile::PdfExtraction

  extend ActiveSupport::Concern

  STATUSES = %w[pending extracted partial failed encrypted].freeze
  MAX_PAGES = 500
  TIME_BUDGET = 5.minutes
  # A command isn't started with less time than this left; its pages are
  # skipped instead.
  MIN_COMMAND_SECONDS = 2
  MAX_JOINED_BYTES = FieldFile::TextExtraction::MAX_BYTES
  PAGE_SEPARATOR = "\n\n"
  TOO_LONG = "Reading the file took too long".freeze
  # Imprimatur 0.6.1's read/pdf/isolation/stream.rs timeout classification,
  # rendered by error.rs. Output-limit skips have a different reason.
  NATIVE_TIMEOUT_REASONS = [
    "the document exceeds the time limit",
    "the document exceeds the render worker wall time limit",
    "the document exceeds the PDF worker limit limit"
  ].freeze

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

  # Every page read whole, from its own text or a model's transcription, and
  # all of it in the search text. A page with no text of its own and no
  # transcription counts against this: what is on it is unknown.
  def pdf_complete?
    return false unless pdf_status == "extracted"

    coverage = pdf_coverage || {}
    coverage.fetch("covered", coverage["text"]).to_i == pdf_page_count.to_i && !coverage["search_text_truncated"] && coverage["ocr"] != "pending"
  end

  # Reads the file and stores what came out. Safe to run again: the pages are
  # replaced as a whole. update_columns, as for text files: derived data, not
  # an edit. Then summarised if there is text (which leaves the house; see
  # FieldSummaries).
  def extract_pdf!(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    return false unless kept? && pdf?

    deadline = Deadline.new(clock, TIME_BUDGET)
    result = file.open { |tempfile| read_pdf(tempfile.path, deadline) }
    store_pdf_result(result)
    broadcast_refresh
    # Scanned or nearly empty pages are transcribed first (FieldOcr), and the
    # summary written once that's done. "pending" was stored with the text,
    # in the same write, so no summary can slip in between.
    if pdf_transcription_pending?
      FieldFiles::OcrPdfJob.perform_later(id)
    else
      enqueue_summary
    end
    true
  end

  # Recomputes the joined text and coverage from the stored pages, after
  # their transcriptions change. The PDF is not read again.
  def restate_pdf!(ocr: nil)
    rows = pages.map { |page| PAGE_COLUMNS.index_with { page[it] } }
    coverage = pdf_coverage || {}
    result = { page_count: pdf_page_count, listed: coverage["listed"].to_i }
    joined, joined_truncated = joined_text(rows)
    coverage = coverage_for(rows, result, joined_truncated).merge("ocr" => ocr || coverage["ocr"]).compact
    status, reason = outcome(coverage)
    update_columns(pdf_status: status, pdf_status_reason: reason&.truncate(500), pdf_coverage: coverage,
      extracted_text: joined, text_extracted_at: Time.current)
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
      pages_truncated: coverage["truncated"].to_i,
      pages_listed: coverage["listed"].to_i,
      search_text_truncated: coverage["search_text_truncated"] == true,
      # Pages a model transcribed from an image of the page (FieldOcr):
      # pages_transcribed have text, pages_transcribed_blank had none to read.
      pages_transcribed: coverage["model_text"].to_i,
      pages_transcribed_blank: coverage["model_empty"].to_i,
      pages_transcription_failed: coverage["model_failed"].to_i,
      pages_transcription_skipped: coverage["model_skipped"].to_i,
      pages_transcription_cut: coverage["model_cut"].to_i,
      transcription: coverage["ocr"],
      complete: pdf_complete?,
      text_source: coverage["model_text"].to_i.positive? ? "native+model" : "native"
    }
  end

  # For the summary prompt: what the material is and which parts of the PDF
  # it doesn't cover. Metadata, kept apart from the document's own text.
  def pdf_summary_coverage
    return nil unless pdf_readable?

    unread = pages.where.not(native_status: "text").where("model_status IS NULL OR model_status NOT IN ('text', 'empty')")
    by_status = unread.pluck(:page_number, :native_status).group_by(&:last)
    listed = (pdf_coverage || {})["listed"].to_i
    parts = [ "This is the text of a PDF of #{pdf_page_count} #{"page".pluralize(pdf_page_count)}." ]
    transcribed = pages.where(model_status: "text").pluck(:page_number)
    if transcribed.any?
      parts << "#{Pages.describe(transcribed)}: transcribed by a model from an image of the page, so may contain mistakes."
    end
    {
      "empty" => "no text of their own (blank or scanned) and were not read",
      "failed" => "could not be read",
      "skipped" => "were not read (a limit was reached)"
    }.each do |status, words|
      numbers = Array(by_status[status]).map(&:first)
      # Pages past the listed ones have no row: a range, never expanded.
      tail = (listed + 1)..pdf_page_count.to_i if status == "skipped" && pdf_page_count.to_i > listed
      parts << "#{Pages.describe(numbers, tail: tail)} #{words}." if numbers.any? || tail
    end
    truncated = pages.where(native_status: "text").where("native_reason IS NOT NULL").pluck(:page_number)
    parts << "#{Pages.describe(truncated)}: text cut short." if truncated.any?
    cut = pages.where(model_status: "text").where("model_reason IS NOT NULL").pluck(:page_number)
    parts << "#{Pages.describe(cut)}: transcription cut short." if cut.any?
    # A page with a little text of its own over a picture that wasn't
    # transcribed: the picture's text is unread even though the page has some.
    picture_unread = pages.where(native_status: "text", model_status: %w[failed skipped]).pluck(:page_number)
    if picture_unread.any?
      parts << "#{Pages.describe(picture_unread)}: a picture on the page could not be transcribed, so its text is not included."
    end
    parts << "Only the beginning of the text is included." if (pdf_coverage || {})["search_text_truncated"]
    return nil if parts.size == 1

    parts << "Summarise only what is in the material and don't guess at what the unread parts contain."
    parts.join(" ")
  end

  # "Page 3", "Pages 3-4, 7", "Pages 499-500, 501-10000". numbers are at most
  # MAX_PAGES row numbers; tail is a Range past them, described from its ends.
  module Pages

    module_function

    def describe(numbers, tail: nil)
      ranges = numbers.sort.slice_when { |a, b| b != a + 1 }.map { span(it.first, it.last) }
      ranges << span(tail.first, tail.last) if tail
      count = numbers.size + (tail ? tail.size : 0)
      "#{count == 1 ? "Page" : "Pages"} #{ranges.join(", ")}"
    end

    def span(first, last) = first == last ? first.to_s : "#{first}-#{last}"

  end

  # Time left in the read; every command is given at most this.
  class Deadline

    def initialize(clock, budget)
      @clock = clock
      @ends = clock.call + budget.to_f
    end

    def remaining = @ends - @clock.call

    # A command's timeout: its own limit or what is left, whichever is
    # smaller; nil when too little is left to start one.
    def allow(limit)
      left = remaining
      left >= MIN_COMMAND_SECONDS ? [ limit, left.floor ].min : nil
    end

  end

  private

  def read_pdf(path, deadline)
    info_timeout = deadline.allow(PdfText::INFO_TIMEOUT) or return { status: "failed", reason: TOO_LONG }
    info = PdfText.info(path, timeout: info_timeout)
    listed = [ info[:pages], MAX_PAGES ].min
    rows = []

    (1..listed).each_slice(PdfText::BATCH_PAGES) { |numbers| rows.concat(read_batch(path, numbers, deadline)) }
    { page_count: info[:pages], listed: listed, pages: rows }
  rescue Imprimatur::PasswordRequired
    { status: "encrypted", reason: "The PDF needs a password to open" }
  rescue Imprimatur::UnsupportedDocument
    { status: "failed", reason: "Not a PDF the house can open" }
  rescue Imprimatur::Error, SystemCallError, IOError => e
    { status: "failed", reason: e.message }
  end

  # The native reader keeps healthy pages when another page is damaged.
  # Pages the deadline doesn't reach are skipped; what was read is kept.
  def read_batch(path, numbers, deadline)
    timeout = deadline.allow(PdfText::BATCH_TIMEOUT)
    return numbers.map { |n| page_row(n, "skipped", reason: TOO_LONG) } unless timeout

    pages = PdfText.pages(path, numbers.first, numbers.last, timeout: timeout)
    rows = pages.to_h { |page| [ page[:page], text_row(page[:page], page) ] }
    unread = pages.select { |page| page[:status] == "skipped" && NATIVE_TIMEOUT_REASONS.include?(page[:reason]) }
      .map { |page| page[:page] }
    # Default unattempted candidates to document exhaustion. Each attempted
    # singleton replaces only its own row, with no recursive recovery.
    unread.each { |n| rows[n] = page_row(n, "skipped", reason: TOO_LONG) }
    # The first missing page may have stalled the worker. Read its later
    # neighbours first, while the original document deadline still has room.
    unread.rotate.each do |number|
      timeout = deadline.allow(PdfText::BATCH_TIMEOUT) or break

      begin
        page = PdfText.pages(path, number, number, timeout: timeout).first
        rows[number] = text_row(number, page)
      rescue Imprimatur::Error, SystemCallError, IOError => e
        rows[number] = page_row(number, "failed", reason: e.message)
      end
    end
    numbers.map { |n| rows.fetch(n) }
  rescue Imprimatur::Error, SystemCallError, IOError => e
    numbers.map { |n| page_row(n, "failed", reason: e.message) }
  end

  def text_row(number, page)
    status = page[:status]
    status = "empty" if status == "text" && page[:text].strip.empty?
    reason = page[:reason]
    if page[:truncated]
      reason = "Text cut at #{PdfText::MAX_PAGE_BYTES / 1.kilobyte} kB; the rest of this page was not read"
    end
    row = page_row(number, status, text: page[:text], reason: reason)
    row[:has_images] = page[:images].positive? unless page[:images].nil?
    row
  end

  def page_row(number, status, text: nil, reason: nil)
    { page_number: number, native_status: status, native_text: (text if status == "text"), native_reason: reason&.truncate(500),
      has_images: nil }
  end

  PAGE_COLUMNS = %i[page_number native_status native_text native_reason has_images model_status model_text model_reason model_id].freeze
  MODEL_COLUMNS = %i[model_status model_text model_reason model_id].freeze

  def store_pdf_result(result)
    now = Time.current
    # A page's transcription outlives a fresh read of the file: it was paid
    # for, and FieldOcr won't pay for the same page twice.
    kept = pages.where.not(model_status: nil).to_h { |page| [ page.page_number, MODEL_COLUMNS.index_with { page[it] } ] }
    rows = Array(result[:pages]).sort_by { it[:page_number] }
      .map { |row| MODEL_COLUMNS.index_with { nil }.merge(row).merge(kept[row[:page_number]] || {}) }
    joined, joined_truncated = joined_text(rows)
    coverage = result[:status] ? nil : coverage_for(rows, result, joined_truncated)
    if coverage && FieldOcr.eligible?(self) && rows.any? { FieldOcr.candidate?(it) && it[:model_status].nil? }
      coverage["ocr"] = "pending"
    end
    status, reason = result[:status] ? [ result[:status], result[:reason] ] : outcome(coverage)

    with_lock do
      pages.delete_all
      FieldFilePage.insert_all(rows.map { it.merge(field_file_id: id, created_at: now, updated_at: now) }) if rows.any?
      pages.reset # insert_all bypasses the association, which delete_all left loaded and empty
      update_columns(
        pdf_status: status, pdf_status_reason: reason&.truncate(500),
        pdf_page_count: result[:page_count], pdf_coverage: coverage,
        extracted_text: joined, text_extracted_at: now
      )
    end
  end

  # Page counts by state. Pages past the listed ones have no row and are
  # counted as skipped.
  def coverage_for(rows, result, joined_truncated)
    counts = rows.group_by { it[:native_status] }.transform_values(&:size)
    rows.filter_map { it[:model_status] }.tally.each { |status, n| counts["model_#{status}"] = n }
    # A page is covered by its own text, or by a transcription that wasn't
    # cut short (model_reason set), or by the model finding it blank.
    whole_model = ->(row) { row[:model_status] == "empty" || (row[:model_status] == "text" && row[:model_reason].nil?) }
    # A transcription that failed or was skipped leaves a picture unread, so
    # that page isn't covered even if it has a little text of its own.
    # Once a page was sent, only a whole transcription covers it: the page's
    # own few words can't vouch for the picture under them.
    own = ->(row) { row[:native_status] == "text" && row[:native_reason].nil? && row[:model_status].nil? }
    counts["covered"] = rows.count { own.(it) || whole_model.(it) }
    cut = rows.count { it[:model_status] == "text" && it[:model_reason] }
    counts["model_cut"] = cut if cut.positive?
    tail = result[:page_count].to_i - result[:listed].to_i
    counts["skipped"] = counts["skipped"].to_i + tail if tail.positive?
    truncated = rows.count { it[:native_status] == "text" && it[:native_reason] }
    counts["truncated"] = truncated if truncated.positive?
    counts.merge("listed" => result[:listed].to_i, "search_text_truncated" => joined_truncated)
  end

  def outcome(coverage)
    failed, skipped, truncated = coverage["failed"].to_i, coverage["skipped"].to_i, coverage["truncated"].to_i
    return [ "extracted", nil ] if failed.zero? && skipped.zero? && truncated.zero?

    parts = []
    parts << "#{failed} #{"page".pluralize(failed)} could not be read" if failed.positive?
    parts << "#{skipped} #{"page".pluralize(skipped)} not read (a limit was reached)" if skipped.positive?
    parts << "#{truncated} #{"page".pluralize(truncated)} cut short (too much text)" if truncated.positive?
    [ "partial", parts.join("; ") ]
  end

  # The pages' text in order, for search and summaries, cut whole-page where
  # it can be and never mid-character. => [text, cut?]
  def joined_text(rows)
    joined = +""
    rows.each do |row|
      text = [ row[:native_text], row[:model_text] ].compact_blank.join("\n")
      next if text.blank?

      piece = joined.empty? ? text : PAGE_SEPARATOR + text
      if joined.bytesize + piece.bytesize > MAX_JOINED_BYTES
        joined << piece.byteslice(0, MAX_JOINED_BYTES - joined.bytesize).scrub("")
        return [ joined, true ]
      end
      joined << piece
    end
    [ joined, false ]
  end

end
