require "test_helper"
require "support/field_ocr_helpers"

# Field OCR with a fake model (FieldOcrHelpers::FakeVision). Poppler renders
# the synthetic fixtures for real; nothing is sent anywhere.
class FieldOcrTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include FieldOcrHelpers

  setup do
    @account = agents(:research_assistant).account
    @user = users(:user_1)
    enable_field_ocr
  end

  teardown { disable_field_ocr }

  test "a scanned page is sent as a bounded image, transcribed, labelled and searchable" do
    file = field_pdf(@account, "scanned_only.pdf", user: @user)
    assert_enqueued_with(job: FieldFiles::OcrPdfJob, args: [ file.id ]) { file.extract_pdf! }
    assert_equal "pending", file.reload.pdf_extraction_json[:transcription]
    assert_not file.pdf_complete?, "not complete while pages wait to be transcribed"

    vision = FakeVision.new([ "Scanned receipt: 3 crates of figs, 42 euros." ])
    assert file.transcribe_pdf!(inference: vision)
    file.reload

    call = vision.calls.sole
    assert_equal FieldOcr::MODEL, call[:model]
    assert_equal "anthropic", call[:provider]
    assert_equal "Page 1 of 1. Transcribe it.\n", call[:text]
    assert call[:image_png].start_with?("\x89PNG".b)
    assert_operator png_size(call[:image_png]).max, :<=, PdfText::RENDER_LONG_SIDE

    page = file.pages.sole
    assert_equal "empty", page.native_status
    assert_equal "text", page.model_status
    assert_equal "model", page.source
    assert_equal FieldOcr::MODEL, page.model_id
    assert_includes file.extracted_text, "crates of figs"
    json = file.pdf_extraction_json
    assert_equal 1, json[:pages_transcribed]
    assert_equal "done", json[:transcription]
    assert_equal "native+model", json[:text_source]
    assert json[:complete]
    assert_equal [ file.id ], FieldSearch.new(account: @account, query: "figs crates").call.results.map { it.record.id }

    ledger = FieldOcrCall.where(field_file: file).sole
    assert_equal "settled", ledger.status
    assert_equal BigDecimal("0.0008"), ledger.charge_usd
    assert_equal "gen-1", ledger.upstream_id
  end

  test "a native heading over a scanned body keeps both texts, apart" do
    file = field_pdf(@account, "heading_over_scan.pdf")
    file.extract_pdf!
    file.transcribe_pdf!(inference: FakeVision.new([ "Quarterly note\nBody text that exists only as pixels." ]))
    page = file.reload.pages.sole

    assert_equal "Quarterly note", page.native_text
    assert_equal "Quarterly note\nBody text that exists only as pixels.", page.model_text
    assert_equal "native+model", page.source
    assert_includes file.extracted_text, "only as pixels"
  end

  test "only scanned or nearly empty pages are sent; a blank page comes back blank" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    vision = FakeVision.new([ "Scanned receipt.", FieldOcr::NO_TEXT ])
    file.transcribe_pdf!(inference: vision)
    file.reload

    assert_equal [ "Page 3 of 4. Transcribe it.\n", "Page 4 of 4. Transcribe it.\n" ], vision.calls.map { it[:text] }
    assert_equal [ nil, nil, "text", "empty" ], file.pages.map(&:model_status)
    assert_nil file.pages.last.model_text
    assert file.pdf_complete?
  end

  test "a retried job pays for nothing twice, and re-reading the file keeps the transcriptions" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    file.transcribe_pdf!(inference: FakeVision.new([ "Scanned receipt.", FieldOcr::NO_TEXT ]))

    again = FakeVision.new
    file.transcribe_pdf!(inference: again)
    assert_empty again.calls

    assert_no_enqueued_jobs(only: FieldFiles::OcrPdfJob) { file.extract_pdf! }
    file.reload
    assert_equal [ nil, nil, "text", "empty" ], file.pages.map(&:model_status)
    assert_equal "Scanned receipt.", file.pages.third.model_text
    assert_equal 2, FieldOcrCall.where(field_file: file).count
  end

  test "a page reserved by another worker is left to it" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    FieldOcrCall.create!(account: @account, field_file: file, page_number: 1, day: FieldOcr.day,
      charge_usd: FieldOcr::RESERVE_USD, model_id: FieldOcr::MODEL)

    vision = FakeVision.new
    file.transcribe_pdf!(inference: vision)
    assert_empty vision.calls
    assert_nil file.reload.pages.sole.model_status
  end

  test "a failed call keeps its charge and the page's own text; it isn't retried on its own" do
    file = field_pdf(@account, "heading_over_scan.pdf")
    file.extract_pdf!
    file.transcribe_pdf!(inference: FakeVision.new([ UtilityInference::InvalidResponse.new("boom") ]))
    file.reload

    page = file.pages.sole
    assert_equal "failed", page.model_status
    assert_equal "The transcription failed", page.model_reason
    assert_equal "Quarterly note", page.native_text
    assert_includes file.extracted_text, "Quarterly note"
    ledger = FieldOcrCall.where(field_file: file).sole
    assert_equal "failed", ledger.status
    assert_equal FieldOcr::RESERVE_USD, ledger.charge_usd
    assert_equal 1, file.pdf_extraction_json[:pages_transcription_failed]
    assert_not file.pdf_complete?, "the picture under the heading is still unread"

    again = FakeVision.new
    file.transcribe_pdf!(inference: again)
    assert_empty again.calls
  end

  test "a page that can't be rendered gives its reservation back" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    vision = FakeVision.new
    PdfText.stub(:render_page, ->(*, **) { raise PdfText::CommandFailed, "pdftoppm took too long" }) do
      file.transcribe_pdf!(inference: vision)
    end

    assert_empty vision.calls
    assert_match(/could not be turned into an image/, file.reload.pages.sole.model_reason)
    ledger = FieldOcrCall.where(field_file: file).sole
    assert_equal [ "failed", 0 ], [ ledger.status, ledger.charge_usd ]
  end

  test "a transcription cut off at the token limit says so" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    vision = FakeVision.new
    vision.define_singleton_method(:house_vision) { |**| { text: "Half a page", usage: { "cost" => 0.002 }, id: "g", finish_reason: "length" } }
    file.transcribe_pdf!(inference: vision)

    assert_equal "The transcription was cut short (token limit)", file.reload.pages.sole.model_reason
  end

  test "a transcription the provider stopped is marked cut, never complete" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    vision = FakeVision.new
    vision.define_singleton_method(:house_vision) { |**| { text: "First line only", usage: { "cost" => 0.0003 }, id: "g", finish_reason: "content_filter" } }
    file.transcribe_pdf!(inference: vision)
    page = file.reload.pages.sole

    assert_equal "text", page.model_status
    assert_equal "The transcription was cut short (stopped by the provider)", page.model_reason
  end

  test "a cut answer with no text is a failure, not a blank page" do
    result = FieldOcr.transcribe("png", page_number: 1, page_count: 1, timeout: 30,
      inference: Struct.new(:x) { def house_vision(**) = { text: "", usage: nil, id: "g", finish_reason: "content_filter" } }.new)
    assert_equal [ "failed", true ], result.values_at(:status, :cut)
    result = FieldOcr.transcribe("png", page_number: 1, page_count: 1, timeout: 30,
      inference: Struct.new(:x) { def house_vision(**) = { text: "[no text]", usage: nil, id: "g", finish_reason: "stop" } }.new)
    assert_equal [ "empty", false ], result.values_at(:status, :cut)
  end

  test "an unknown cost keeps the reserved charge" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    vision = FakeVision.new
    vision.define_singleton_method(:house_vision) { |**| { text: "Text", usage: nil, id: "g", finish_reason: "stop" } }
    file.transcribe_pdf!(inference: vision)

    ledger = FieldOcrCall.where(field_file: file).sole
    assert_equal [ "uncertain", FieldOcr::RESERVE_USD ], [ ledger.status, ledger.charge_usd ]
  end

  test "the house's daily ceiling stops further pages, which are skipped with the reason" do
    Setting.instance.update!(field_ocr_daily_usd_ceiling: BigDecimal("0.0035"))
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    vision = FakeVision.new
    file.transcribe_pdf!(inference: vision)
    file.reload

    assert_equal 1, vision.calls.size, "0.0008 settled + 0.003 reserved would pass 0.0035"
    assert_equal "skipped", file.pages.last.model_status
    assert_equal "The house's transcription budget for today is used up", file.pages.last.model_reason
    assert_equal 1, file.pdf_extraction_json[:pages_transcription_skipped]
    assert_not file.pdf_complete?
  end

  test "a zero ceiling sends nothing" do
    Setting.instance.update!(field_ocr_daily_usd_ceiling: 0)
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    vision = FakeVision.new
    file.transcribe_pdf!(inference: vision)
    assert_empty vision.calls
    assert_empty FieldOcrCall.where(field_file: file)
  end

  test "per-file and per-account limits" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    with_constant(FieldOcr, :MAX_PAGES_PER_FILE, 1) { file.transcribe_pdf!(inference: FakeVision.new) }
    assert_equal "Only 1 pages of a file are transcribed", file.reload.pages.last.model_reason

    other = field_pdf(@account, "scanned_only.pdf")
    other.extract_pdf!
    vision = FakeVision.new
    with_constant(FieldOcr, :MAX_PAGES_PER_ACCOUNT_PER_DAY, 1) { other.transcribe_pdf!(inference: vision) }
    assert_empty vision.calls
    assert_equal "This account's transcriptions for today are used up", other.reload.pages.sole.model_reason
  end

  test "nothing is sent while OCR is off, nor for files brought in before it was turned on" do
    disable_field_ocr
    off = field_pdf(@account, "scanned_only.pdf")
    assert_no_enqueued_jobs(only: FieldFiles::OcrPdfJob) { off.extract_pdf! }
    assert_not off.transcribe_pdf!(inference: FakeVision.new)

    enable_field_ocr
    Setting.instance.update!(field_ocr_enabled: false)
    Setting.instance.update!(field_ocr_enabled: true)
    assert_operator Setting.instance.field_ocr_enabled_at, :>, off.created_at
    vision = FakeVision.new
    assert_no_enqueued_jobs(only: FieldFiles::OcrPdfJob) { off.extract_pdf! }
    assert_not off.transcribe_pdf!(inference: vision)
    assert_empty vision.calls
  end

  test "turning OCR on stamps the moment; the ceiling is bounded" do
    setting = Setting.instance
    setting.update!(field_ocr_enabled: false)
    freeze_time do
      setting.update!(field_ocr_enabled: true)
      assert_equal Time.current, setting.field_ocr_enabled_at
    end
    assert_not setting.update(field_ocr_daily_usd_ceiling: -1)
    assert_not setting.update(field_ocr_daily_usd_ceiling: 101)
  end

  test "the summary prompt names transcribed pages as a model's" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    file.transcribe_pdf!(inference: FakeVision.new([ "Scanned receipt.", FieldOcr::NO_TEXT ]))
    prompt = FieldSummaries.user_prompt(file.reload)

    coverage, material = prompt.split("<material>", 2)
    assert_includes coverage, "Page 3: transcribed by a model from an image of the page, so may contain mistakes."
    assert_not_includes coverage, "not read"
    assert_includes material, "Scanned receipt."
  end

  test "pages carry the transcription apart from the page's own text" do
    file = field_pdf(@account, "heading_over_scan.pdf")
    file.extract_pdf!
    file.transcribe_pdf!(inference: FakeVision.new([ "Quarterly note\nBody." ]))
    json = file.reload.pages.sole.reader_json(text: true)

    assert_equal "Quarterly note", json[:text]
    assert_equal "native+model", json[:source]
    assert_equal({ status: "text", model: FieldOcr::MODEL, reason: nil, characters: 20, text: "Quarterly note\nBody." }, json[:transcription])
    assert_not file.pages.sole.reader_json(text: false)[:transcription].key?(:text)
  end

  test "the model's answer is cleaned and capped" do
    vision = FakeVision.new([ " \u0000Hello\u0000 " ])
    result = FieldOcr.transcribe("png", page_number: 1, page_count: 1, timeout: 30, inference: vision)
    assert_equal [ "text", "Hello", false ], result.values_at(:status, :text, :cut)

    with_constant(FieldOcr, :MAX_TEXT_CHARS, 3) do
      result = FieldOcr.transcribe("png", page_number: 1, page_count: 1, timeout: 30, inference: FakeVision.new([ "Hello" ]))
      assert_equal [ "Hel", true ], result.values_at(:text, :cut)
    end
  end

  # --- Mira's review of cc37f12 ---

  test "while transcription is pending, neither the sweep nor a direct job can summarise" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    file.reload
    assert file.pdf_transcription_pending?, "pending is stored with the text, in the same write"

    assert_not_includes FieldFile.summary_readable, file
    assert_not_includes FieldFile.summary_due, file
    assert_not file.summarizable?
    assert_not file.claim_summary!

    file.transcribe_pdf!(inference: FakeVision.new([ "Scanned receipt.", FieldOcr::NO_TEXT ]))
    file.reload
    assert_includes FieldFile.summary_due, file
    assert file.claim_summary!
  end

  test "a scanned-only file waiting on OCR isn't retired as blank, and is summarised once transcribed" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    file.reload
    assert file.pdf_transcription_pending?
    assert_equal "", file.extracted_text

    assert_not file.claim_summary!
    assert_equal 0, file.reload.summary_attempts, "not retired while its text may still arrive"
    assert_not file.summary_source_blank?

    file.transcribe_pdf!(inference: FakeVision.new([ "Scanned receipt: 3 crates of figs." ]))
    assert file.reload.claim_summary!
    assert_equal 1, file.summary_attempts
  end

  test "a scanned file that turns out blank is still retired, once transcription is done" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    file.transcribe_pdf!(inference: FakeVision.new([ FieldOcr::NO_TEXT ]))
    file.reload

    assert file.summary_source_blank?
    assert_not file.claim_summary!
    assert_equal FieldSummarizable::MAX_ATTEMPTS, file.reload.summary_attempts
  end

  test "a page held by another worker keeps the file pending and looks again later" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    FieldOcrCall.create!(account: @account, field_file: file, page_number: 3, day: FieldOcr.day,
      charge_usd: FieldOcr::RESERVE_USD, model_id: FieldOcr::MODEL)

    vision = FakeVision.new([ FieldOcr::NO_TEXT ])
    assert_enqueued_with(job: FieldFiles::OcrPdfJob, args: [ file.id ]) { file.transcribe_pdf!(inference: vision) }
    file.reload

    assert_equal [ "Page 4 of 4. Transcribe it.\n" ], vision.calls.map { it[:text] }
    assert_nil file.pages.third.model_status
    assert file.pdf_transcription_pending?
    assert_not file.summarizable?
  end

  test "turned off while pending, the file still reaches an honest end" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    Setting.instance.update!(field_ocr_enabled: false)

    vision = FakeVision.new
    assert file.transcribe_pdf!(inference: vision)
    file.reload
    assert_empty vision.calls
    assert_equal [ nil, nil, "skipped", "skipped" ], file.pages.map(&:model_status)
    assert_equal "Transcription was turned off", file.pages.last.model_reason
    assert_equal "done", file.pdf_extraction_json[:transcription]
    assert_not file.pdf_complete?
    assert file.summarizable?
  end

  test "a heading cannot vouch for a cut transcription of the scan under it" do
    %w[length content_filter].each do |finish|
      file = field_pdf(@account, "heading_over_scan.pdf")
      file.extract_pdf!
      vision = FakeVision.new
      vision.define_singleton_method(:house_vision) { |**| { text: "Quarterly note\nBody", usage: { "cost" => 0.0003 }, id: "g", finish_reason: finish } }
      file.transcribe_pdf!(inference: vision)
      file.reload

      assert_equal 1, file.pdf_extraction_json[:pages_transcription_cut], finish
      assert_not file.pdf_extraction_json[:complete], finish
      assert_includes FieldSummaries.user_prompt(file), "Page 1: transcription cut short.", finish
    end
  end

  test "a heading over a scan that wasn't transcribed says the picture is unread" do
    failed = field_pdf(@account, "heading_over_scan.pdf")
    failed.extract_pdf!
    failed.transcribe_pdf!(inference: FakeVision.new([ UtilityInference::InvalidResponse.new("boom") ]))

    Setting.instance.update!(field_ocr_daily_usd_ceiling: 0)
    skipped = field_pdf(@account, "heading_over_scan.pdf")
    skipped.extract_pdf!
    skipped.transcribe_pdf!(inference: FakeVision.new)

    [ failed, skipped ].each do |file|
      file.reload
      assert_not file.pdf_complete?
      prompt = FieldSummaries.user_prompt(file)
      assert_includes prompt, "Page 1: a picture on the page could not be transcribed, so its text is not included."
      assert_includes prompt.split("<material>", 2).last, "Quarterly note"
    end
  end

  test "the model call gets no more than the time left after rendering" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    now = 0.0
    real_render = PdfText.method(:render_page)
    slow_render = ->(path, n, timeout:) { now = FieldFile::PdfOcr::OCR_TIME_BUDGET - 30.4; real_render.(path, n, timeout:) }
    vision = FakeVision.new
    PdfText.stub(:render_page, slow_render) { file.transcribe_pdf!(inference: vision, clock: -> { now }) }

    assert_equal 30, vision.calls.sole[:timeout]
  end

  test "rendering that uses up the time stops the call; the reservation is given back" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    now = 0.0
    real_render = PdfText.method(:render_page)
    slow_render = ->(path, n, timeout:) { now = FieldFile::PdfOcr::OCR_TIME_BUDGET - 1; real_render.(path, n, timeout:) }
    vision = FakeVision.new
    PdfText.stub(:render_page, slow_render) { file.transcribe_pdf!(inference: vision, clock: -> { now }) }
    file.reload

    assert_empty vision.calls
    assert_equal [ "skipped", "skipped" ], file.pages.last(2).map(&:model_status)
    assert_equal FieldFile::PdfExtraction::TOO_LONG, file.pages.third.model_reason
    assert_equal [ [ "failed", 0 ] ], FieldOcrCall.where(field_file: file).pluck(:status, :charge_usd)
  end

  test "no command or call outlives the OCR budget" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    now = 0.0
    real_render = PdfText.method(:render_page)
    given = []
    left = -> { 100 - now }
    render = ->(path, n, timeout:) { given << [ :render, timeout, left.() ]; now += timeout; real_render.(path, n, timeout:) }
    vision = FakeVision.new { |params, _| given << [ :call, params[:timeout], left.() ]; now += params[:timeout]; "Text" }
    # A 100-second budget, so the second page meets its end: render 30, call
    # 60, then 10 s left for the second render and nothing for its call.
    with_constant(FieldFile::PdfOcr, :OCR_TIME_BUDGET, 100) do
      PdfText.stub(:render_page, render) { file.transcribe_pdf!(inference: vision, clock: -> { now }) }
    end

    assert given.all? { |_, timeout, remaining| timeout <= remaining }, given.inspect
    assert_operator now, :<=, 100
    assert_equal [ [ :render, 30 ], [ :call, 60 ], [ :render, 10 ] ], given.map { it.first(2) }
    assert_equal "skipped", file.reload.pages.last.model_status
  end

  test "turning OCR off during a call stops the next image leaving" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    vision = FakeVision.new { |_, n| Setting.instance.update!(field_ocr_enabled: false) if n == 1; "Scanned receipt." }
    file.transcribe_pdf!(inference: vision)
    file.reload

    assert_equal 1, vision.calls.size
    assert_equal [ "text", "skipped" ], file.pages.last(2).map(&:model_status)
    assert_equal "Transcription was turned off", file.pages.last.model_reason
    assert_equal 1, FieldOcrCall.where(field_file: file).count
  end

  test "turning OCR off during rendering keeps that image home" do
    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    real_render = PdfText.method(:render_page)
    render = ->(path, n, timeout:) { Setting.instance.update!(field_ocr_enabled: false); real_render.(path, n, timeout:) }
    vision = FakeVision.new
    PdfText.stub(:render_page, render) { file.transcribe_pdf!(inference: vision) }

    assert_empty vision.calls
    assert_equal "Transcription was turned off", file.reload.pages.sole.model_reason
    assert_equal [ [ "failed", 0 ] ], FieldOcrCall.where(field_file: file).pluck(:status, :charge_usd)
  end

  test "discarding the file during a call stops the rest" do
    file = field_pdf(@account, "mixed.pdf")
    file.extract_pdf!
    vision = FakeVision.new { |_, n| FieldFile.find(file.id).discard! if n == 1; "Scanned receipt." }
    assert_not file.transcribe_pdf!(inference: vision)

    assert_equal 1, vision.calls.size
    assert_equal 1, FieldOcrCall.where(field_file: file).count
  end

  # FIELD_OCR_LIVE=1 sends one synthetic page to the real model, on the
  # house key, and prints what it cost. Off in CI.
  test "live: one synthetic scanned page" do
    skip "set FIELD_OCR_LIVE=1 to call the real model" unless ENV["FIELD_OCR_LIVE"] == "1"

    file = field_pdf(@account, "scanned_only.pdf")
    file.extract_pdf!
    live = -> { file.transcribe_pdf! }
    allowed = WebMock::Config.instance.allow_net_connect if defined?(WebMock)
    begin
      WebMock.allow_net_connect! if defined?(WebMock)
      defined?(VCR) ? VCR.turned_off(ignore_cassettes: true) { live.call } : live.call
    ensure
      WebMock::Config.instance.allow_net_connect = allowed if defined?(WebMock)
    end
    file.reload
    call = FieldOcrCall.where(field_file: file).sole
    puts "\nlive OCR: #{file.pages.sole.model_status} #{file.pages.sole.model_text.inspect} cost=#{call.charge_usd} status=#{call.status} upstream=#{call.upstream_id}"
    assert_equal "text", file.pages.sole.model_status
    assert_includes file.pages.sole.model_text.downcase, "figs"
  end

  private

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
