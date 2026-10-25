require "test_helper"

# Synthetic PDFs from test/fixtures/files/field_pdfs (generate.sh). Imprimatur
# runs for real; nothing leaves the machine.
class FieldFilePdfExtractionTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @account = agents(:research_assistant).account
    @user = users(:user_1)
  end

  test "a text PDF is read page by page and becomes searchable" do
    file = perform_enqueued_jobs(only: FieldFiles::ExtractPdfJob) { pdf("text_only.pdf") }.reload

    assert_equal "extracted", file.pdf_status
    assert_nil file.pdf_status_reason
    assert_equal 2, file.pdf_page_count
    assert_equal [ [ 1, "text" ], [ 2, "text" ] ], file.pages.map { [ it.page_number, it.native_status ] }
    assert_equal "Orchard ledger, page one: apricots and quinces.", file.pages.first.native_text
    assert_includes file.extracted_text, "walnut harvest"
    assert file.text_extracted_at
    assert_equal [ file.id ], FieldSearch.new(account: @account, query: "walnut quinces").call.results.map { it.record.id }
    assert_includes FieldFile.summary_readable, file
  end

  test "the job is queued for PDFs only, and the file starts pending" do
    file = nil
    assert_enqueued_with(job: FieldFiles::ExtractPdfJob) { file = pdf("text_only.pdf") }
    assert_equal "pending", file.pdf_status

    assert_no_enqueued_jobs(only: FieldFiles::ExtractPdfJob) do
      plain = @account.field_files.create!(file: upload("notes.txt", "text/plain"), uploaded_by: @user)
      assert_nil plain.pdf_status
    end
  end

  test "a scanned page has no text layer: empty, not failed, and not searchable text" do
    file = pdf("scanned_only.pdf")
    assert file.extract_pdf!
    file.reload

    assert_equal "extracted", file.pdf_status
    assert_equal [ "empty" ], file.pages.map(&:native_status)
    assert_nil file.pages.first.native_text
    assert_equal "", file.extracted_text
    assert_not_includes FieldFile.summary_readable, file
    assert_equal({ "empty" => 1, "listed" => 1, "covered" => 0, "search_text_truncated" => false }, file.pdf_coverage)
    assert_not file.pdf_extraction_json[:complete], "a page without a text layer is unknown, not read"
  end

  test "mixed PDFs keep each page's own state" do
    file = pdf("mixed.pdf")
    file.extract_pdf!
    file.reload

    assert_equal 4, file.pdf_page_count
    assert_equal %w[text text empty empty], file.pages.map(&:native_status)
    json = file.pdf_extraction_json
    assert_equal 2, json[:pages_with_text]
    assert_equal 2, json[:pages_without_text]
    assert_equal "native", json[:text_source]
  end

  test "a native heading over a scanned body keeps the heading; the scanned body is not invented" do
    file = pdf("heading_over_scan.pdf")
    file.extract_pdf!
    page = file.reload.pages.first

    assert_equal "text", page.native_status
    assert_equal "Quarterly note", page.native_text
    assert_not_includes file.extracted_text, "pixels"
  end

  test "a PDF that needs a password is encrypted and nothing is read" do
    file = pdf("encrypted.pdf")
    file.extract_pdf!
    file.reload

    assert_equal "encrypted", file.pdf_status
    assert_equal "The PDF needs a password to open", file.pdf_status_reason
    assert_empty file.pages
    assert_nil file.pdf_page_count
  end

  test "permission flags alone do not stop the text being read" do
    file = pdf("permissions_only.pdf")
    file.extract_pdf!

    assert_equal "extracted", file.reload.pdf_status
    assert_includes file.extracted_text, "apricots"
  end

  test "a file that is not really a PDF fails with a reason" do
    file = pdf("broken.pdf")
    file.extract_pdf!
    file.reload

    assert_equal "failed", file.pdf_status
    assert_equal "Not a PDF the house can open", file.pdf_status_reason
    assert_empty file.pages
  end

  test "pages past the page limit get no rows, are counted as skipped, and the file is partial" do
    file = pdf("mixed.pdf")
    with_constant(FieldFile::PdfExtraction, :MAX_PAGES, 1) { file.extract_pdf! }
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal "3 pages not read (a limit was reached)", file.pdf_status_reason
    assert_equal %w[text], file.pages.map(&:native_status)
    json = file.pdf_extraction_json
    assert_equal 1, json[:pages_listed]
    assert_equal 3, json[:pages_skipped]
    assert_not json[:complete]
    assert_includes file.extracted_text, "apricots"
  end

  test "pages not reached within the time budget are skipped, and what was read is kept" do
    file = pdf("mixed.pdf")
    ticks = [ 0, 0, 0, 10_000 ].each
    with_constant(PdfText, :BATCH_PAGES, 2) do
      file.extract_pdf!(clock: -> { ticks.next rescue 10_000 })
    end
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal %w[text text skipped skipped], file.pages.map(&:native_status)
    assert_equal "Reading the file took too long", file.pages.last.native_reason
    assert_includes file.extracted_text, "walnut"
  end

  test "an expired native read marks its pages failed rather than blank" do
    file = pdf("text_only.pdf")
    with_constant(PdfText, :BATCH_TIMEOUT, 0) { file.extract_pdf! }
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal %w[failed failed], file.pages.map(&:native_status)
    assert file.pages.all? { it.native_reason.present? }
    assert_empty file.extracted_text
  end

  test "a damaged content stream fails alone without losing healthy pages" do
    bytes = Imprimatur.pdf do |doc|
      doc.paragraph("Healthy first page")
      doc.page_break
      doc.paragraph("Broken second page")
      doc.page_break
      doc.paragraph("Healthy third page")
    end
    streams = bytes.to_enum(:scan, /\bstream\r?\n/).map { Regexp.last_match.end(0) }
    bytes.setbyte(streams.fetch(1), 0) # Damage Flate data without moving the xref.
    file = generated_pdf(bytes)
    file.extract_pdf!
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal "1 page could not be read", file.pdf_status_reason
    assert_equal %w[text failed text], file.pages.map(&:native_status)
    assert file.pages.second.native_reason.present?
    assert_includes file.extracted_text, "Healthy first page"
    assert_includes file.extracted_text, "Healthy third page"
  end

  test "a thrown decompression limit preserves healthy pages in the batch" do
    file = generated_pdf(Imprimatur.pdf do |doc|
      doc.paragraph("Healthy first page")
      doc.page_break
      doc.paragraph("x" * 2000)
      doc.page_break
      doc.paragraph("Healthy third page")
    end)
    with_constant(PdfText, :MAX_INFLATED_BYTES, 1024) { file.extract_pdf! }
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal %w[text failed text], file.pages.map(&:native_status)
    assert file.pages.second.native_reason.present?
    assert_includes file.extracted_text, "Healthy first page"
    assert_includes file.extracted_text, "Healthy third page"
    assert_equal 1, file.pdf_extraction_json[:pages_failed]
  end

  test "a page's text over the per-page limit is kept as a prefix and marked cut" do
    file = pdf("text_only.pdf")
    with_constant(PdfText, :MAX_PAGE_BYTES, 10) { file.extract_pdf! }
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal "2 pages cut short (too much text)", file.pdf_status_reason
    page = file.pages.first
    assert_equal "text", page.native_status
    assert_equal "Orchard le", page.native_text
    assert_match(/\AText cut at/, page.native_reason)
    json = file.pdf_extraction_json
    assert_equal 2, json[:pages_truncated]
    assert_not json[:complete]
  end

  test "a page is cut on a character boundary" do
    file = generated_pdf(Imprimatur.pdf { it.paragraph("é" * 4) })
    with_constant(PdfText, :MAX_PAGE_BYTES, 5) do
      file.extract_pdf!
    end
    page = file.reload.pages.sole
    assert_equal "éé", page.native_text
    assert page.native_reason.present?
    assert page.native_text.valid_encoding?
  end

  test "text past the search limit is flagged, not silently complete" do
    file = pdf("text_only.pdf")
    with_constant(FieldFile::PdfExtraction, :MAX_JOINED_BYTES, 20) { file.extract_pdf! }
    file.reload

    assert_equal "extracted", file.pdf_status, "every page was read whole"
    assert_equal 20, file.extracted_text.bytesize
    json = file.pdf_extraction_json
    assert json[:search_text_truncated]
    assert_not json[:complete]
  end

  test "the joined text is capped without cutting a character in half" do
    rows = [ { native_text: "a" * 10 }, { native_text: "é" * 10 } ]
    with_constant(FieldFile::PdfExtraction, :MAX_JOINED_BYTES, 17) do
      joined, cut = FieldFile.new.send(:joined_text, rows)
      assert_equal "a" * 10 + "\n\néé", joined
      assert cut
      assert joined.valid_encoding?
    end
  end

  test "the summary prompt says which pages weren't read, outside the material" do
    file = pdf("mixed.pdf")
    file.extract_pdf!
    prompt = FieldSummaries.user_prompt(file.reload)

    coverage, material = prompt.split("<material>", 2)
    assert_includes coverage, "This is the text of a PDF of 4 pages."
    assert_includes coverage, "Pages 3-4 no text of their own (blank or scanned) and were not read."
    assert_includes coverage, "don't guess"
    assert_includes material, "apricots"
    assert_not_includes material, "blank or scanned"
  end

  test "a partial PDF's summary prompt names failed, skipped and cut pages" do
    file = pdf("mixed.pdf")
    with_constant(FieldFile::PdfExtraction, :MAX_PAGES, 1) { file.extract_pdf! }
    file.reload.pages.first.update!(native_reason: "Text cut at 256 kB; the rest of this page was not read")
    prompt = FieldSummaries.user_prompt(file)

    assert_includes prompt, "Pages 2-4 were not read (a limit was reached)."
    assert_includes prompt, "Page 1: text cut short."
  end

  test "a whole PDF's prompt carries no coverage note, and its summary isn't partial" do
    file = pdf("text_only.pdf")
    file.extract_pdf!
    file.reload
    assert_not_includes FieldSummaries.user_prompt(file), "About the material"

    file.update_columns(summary_long: "An orchard ledger.")
    assert_not file.summary_partial?

    mixed = pdf("mixed.pdf")
    mixed.extract_pdf!
    mixed.reload.update_columns(summary_long: "An orchard ledger.")
    assert mixed.summary_partial?
  end

  test "a summary describes an unread tail as a range without expanding it" do
    file = pdf("mixed.pdf")
    with_constant(FieldFile::PdfExtraction, :MAX_PAGES, 1) { file.extract_pdf! }
    file.reload
    assert_includes FieldFile.summary_readable, file

    prompt = FieldSummaries.user_prompt(file)
    assert_includes prompt, "This is the text of a PDF of 4 pages."
    assert_includes prompt, "Pages 2-4 were not read (a limit was reached)."
    assert_includes prompt.split("<material>", 2).last, "Orchard ledger, page one"

    # The tail is described from its ends, never expanded: a page count far
    # too large to enumerate still describes at once.
    file.update_columns(pdf_page_count: 2_000_000_000)
    assert_includes file.pdf_summary_coverage, "Pages 2-2000000000 were not read (a limit was reached)."
  end

  test "page lists join row pages and the tail" do
    describe = FieldFile::PdfExtraction::Pages.method(:describe)
    assert_equal "Page 3", describe.([ 3 ])
    assert_equal "Pages 3-4, 7", describe.([ 7, 3, 4 ])
    assert_equal "Pages 499-500, 501-9000", describe.([ 499, 500 ], tail: 501..9000)
    assert_equal "Page 501", describe.([], tail: 501..501)
  end

  test "reading again replaces the pages rather than adding to them" do
    file = pdf("text_only.pdf")
    2.times { file.extract_pdf! }
    assert_equal 2, file.reload.pages.count
  end

  test "discarded files are not read" do
    file = pdf("text_only.pdf")
    file.discard!
    assert_not file.extract_pdf!
    assert_equal "pending", file.reload.pdf_status
  end

  test "backfill queues PDFs that were never read" do
    file = pdf("text_only.pdf")
    file.update_columns(pdf_status: nil)
    clear_enqueued_jobs

    assert_enqueued_with(job: FieldFiles::ExtractPdfJob, args: [ file.id ]) { FieldFiles::ExtractPdfJob.backfill }
    assert_equal "pending", file.reload.pdf_status
  end

  private

  def pdf(name)
    @account.field_files.create!(file: upload(name, "application/pdf"), uploaded_by: @user)
  end

  def generated_pdf(bytes)
    @account.field_files.create!(uploaded_by: @user,
      file: { io: StringIO.new(bytes), filename: "generated.pdf", content_type: "application/pdf" })
  end

  def upload(name, type)
    path = Rails.root.join("test/fixtures/files/field_pdfs", name)
    path = Tempfile.new([ "field", ".txt" ]).tap { it.write("hello"); it.flush }.path unless File.exist?(path)
    Rack::Test::UploadedFile.new(path, type, original_filename: name)
  end

  def with_constant(owner, name, value)
    old = owner.const_get(name)
    owner.send(:remove_const, name)
    owner.const_set(name, value)
    yield
  ensure
    owner.send(:remove_const, name)
    owner.const_set(name, old)
  end

end
