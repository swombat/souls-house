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
    assert_equal({ "empty" => 1, "listed" => 1, "search_text_truncated" => false }, file.pdf_coverage)
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

  test "a huge advertised page count materialises rows for the read pages only" do
    file = pdf("text_only.pdf")
    calls = 0
    blank = ->(_path, first, last, **) { calls += 1; (first..last).map { PdfText::Page.new(text: "", truncated: false) } }
    PdfText.stub(:info, { pages: 10_000, permissions_only: false }) do
      PdfText.stub(:pages, blank) { file.extract_pdf! }
    end
    file.reload

    assert_equal FieldFile::PdfExtraction::MAX_PAGES, file.pages.count
    assert_equal FieldFile::PdfExtraction::MAX_PAGES / PdfText::BATCH_PAGES, calls
    json = file.pdf_extraction_json
    assert_equal 10_000, json[:page_count]
    assert_equal 9_500, json[:pages_skipped]
    assert_equal 500, json[:pages_without_text]
    assert_equal "partial", json[:status]
    assert_equal "9500 pages not read (a limit was reached)", json[:reason]
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

  test "the budget holds through the page-by-page fallback: no command outlives it" do
    file = pdf("text_only.pdf")
    now = 0.0
    timeouts = []
    slow = lambda do |_path, _first, _last, timeout:, **|
      timeouts << [ timeout, FieldFile::PdfExtraction::TIME_BUDGET - now ]
      now += timeout + PdfText::KILL_GRACE
      raise PdfText::CommandFailed, "pdftotext took too long"
    end
    PdfText.stub(:info, { pages: 60, permissions_only: false }) do
      PdfText.stub(:pages, slow) { file.extract_pdf!(clock: -> { now }) }
    end
    file.reload

    assert timeouts.all? { |given, left| given <= left }, "every command fits in what was left: #{timeouts.inspect}"
    assert_operator now, :<=, FieldFile::PdfExtraction::TIME_BUDGET + PdfText::KILL_GRACE
    assert_equal 60, file.pages.count
    assert_equal "partial", file.pdf_status
    statuses = file.pages.map(&:native_status).tally
    assert_equal 60, statuses["failed"].to_i + statuses["skipped"].to_i
    assert_operator statuses["skipped"].to_i, :>, 0
    assert_equal "Reading the file took too long", file.pages.last.native_reason
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
    with_constant(PdfText, :MAX_PAGE_BYTES, 5) do
      page = PdfText.clean(("é" * 4).b)
      assert_equal "éé", page.text
      assert page.truncated
      assert page.text.valid_encoding?
    end
    assert_not PdfText.clean("short").truncated
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

  test "commands' stdout and stderr are capped in files, not buffered from pipes" do
    noisy = [ "sh", "-c", "head -c 2000000 /dev/zero; head -c 2000000 /dev/zero >&2" ]
    result = PdfText.run(noisy, timeout: 10, max_bytes: 1_000)

    assert_operator result.stdout.bytesize, :<=, 1_000
    assert_operator result.stderr.bytesize, :<=, PdfText::STDERR_LIMIT
    assert_not result.success, "the child is stopped when it writes past the cap"
  end

  test "commands are killed at their timeout" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = PdfText.run([ "sleep", "30" ], timeout: 1, max_bytes: 1_000)

    assert result.killed
    assert_equal "took too long", result.failure
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1 + PdfText::KILL_GRACE + 2
  end

  test "the summary prompt says which pages weren't read, outside the material" do
    file = pdf("mixed.pdf")
    file.extract_pdf!
    prompt = FieldSummaries.user_prompt(file.reload)

    coverage, material = prompt.split("<material>", 2)
    assert_includes coverage, "This is the text layer of a PDF of 4 pages."
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

  test "a huge PDF with readable text gets a summary prompt naming the unread tail as one range" do
    file = pdf("text_only.pdf")
    one_readable = lambda do |_path, first, last, **|
      (first..last).map { |n| PdfText::Page.new(text: n == 1 ? "Orchard ledger, page one." : "", truncated: false) }
    end
    PdfText.stub(:info, { pages: 10_000, permissions_only: false }) do
      PdfText.stub(:pages, one_readable) { file.extract_pdf! }
    end
    file.reload
    assert_includes FieldFile.summary_readable, file

    prompt = FieldSummaries.user_prompt(file)
    assert_includes prompt, "This is the text layer of a PDF of 10000 pages."
    assert_includes prompt, "Pages 2-500 no text of their own (blank or scanned) and were not read."
    assert_includes prompt, "Pages 501-10000 were not read (a limit was reached)."
    assert_includes prompt.split("<material>", 2).last, "Orchard ledger, page one."

    # The tail is described from its ends, never expanded: a page count far
    # too large to enumerate still describes at once.
    file.update_columns(pdf_page_count: 2_000_000_000)
    assert_includes file.pdf_summary_coverage, "Pages 501-2000000000 were not read (a limit was reached)."
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
