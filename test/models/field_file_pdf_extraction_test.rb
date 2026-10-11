require "test_helper"

# Synthetic PDFs from test/fixtures/files/field_pdfs (generate.sh). Poppler
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
    assert_equal({ "empty" => 1 }, file.pdf_coverage)
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

  test "pages past the page limit are skipped and the file is partial" do
    file = pdf("mixed.pdf")
    with_constant(FieldFile::PdfExtraction, :MAX_PAGES, 1) { file.extract_pdf! }
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal "3 pages not read (a limit was reached)", file.pdf_status_reason
    assert_equal %w[text skipped skipped skipped], file.pages.map(&:native_status)
    assert_equal "Only the first 1 pages are read", file.pages.last.native_reason
    assert_includes file.extracted_text, "apricots"
  end

  test "pages not reached within the time budget are skipped, and what was read is kept" do
    file = pdf("mixed.pdf")
    ticks = [ 0, 0, 10_000 ].each
    with_constant(PdfText, :BATCH_PAGES, 2) do
      file.extract_pdf!(clock: -> { ticks.next rescue 10_000 })
    end
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal %w[text text skipped skipped], file.pages.map(&:native_status)
    assert_equal "Reading the file took too long", file.pages.last.native_reason
    assert_includes file.extracted_text, "walnut"
  end

  test "when a batch fails, pages are read one by one and a failing page fails alone" do
    file = pdf("mixed.pdf")
    real_pages = PdfText.method(:pages)
    failing = lambda do |path, first, last, **options|
      raise PdfText::CommandFailed, "pdftotext took too long" if first != last || first == 2

      real_pages.(path, first, last, **options)
    end
    PdfText.stub(:pages, failing) { file.extract_pdf! }
    file.reload

    assert_equal "partial", file.pdf_status
    assert_equal "1 page could not be read", file.pdf_status_reason
    assert_equal %w[text failed empty empty], file.pages.map(&:native_status)
    assert_equal "pdftotext took too long", file.pages.second.native_reason
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

  test "the joined text is capped without cutting a character in half" do
    rows = [ { native_text: "a" * 10 }, { native_text: "é" * 10 } ]
    with_constant(FieldFile::PdfExtraction, :MAX_JOINED_BYTES, 17) do
      joined = FieldFile.new.send(:joined_text, rows)
      assert_equal "a" * 10 + "\n\néé", joined
      assert joined.valid_encoding?
    end
  end

  private

  def pdf(name)
    @account.field_files.create!(file: upload(name, "application/pdf"), uploaded_by: @user)
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
