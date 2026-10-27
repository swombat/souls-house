require "test_helper"

class FieldFilePdfTimeoutRecoveryTest < ActiveSupport::TestCase

  setup do
    @file = FieldFile.new
    @now = 0
    @deadline = FieldFile::PdfExtraction::Deadline.new(-> { @now }, 100)
  end

  test "completed rows and non-timeout skips survive while later unread neighbours are retried first" do
    pages = [
      page(1, text: "kept", images: 1),
      page(2, status: "empty", text: "", images: 0),
      page(3, text: "prefix", truncated: true, reason: "the page text limit was reached"),
      page(4, status: "failed", reason: "damaged stream"),
      page(5, status: "skipped", reason: "the text output limit was reached"),
      timed_out(6), timed_out(7), timed_out(8)
    ]
    calls = []
    read = ->(path, first, last, timeout:) {
      assert_equal "document.pdf", path
      calls << [ first, last, timeout ]
      first == last ? [ page(first, text: "recovered #{first}") ] : pages
    }

    rows = PdfText.stub(:pages, read) { read_batch(1..8) }

    assert_equal [ [ 1, 8, 60 ], [ 7, 7, 60 ], [ 8, 8, 60 ], [ 6, 6, 60 ] ], calls
    assert_equal (1..8).to_a, rows.pluck(:page_number)
    assert_equal %w[text empty text failed skipped text text text], rows.pluck(:native_status)
    assert_equal "kept", rows[0][:native_text]
    assert_equal true, rows[0][:has_images]
    assert_nil rows[1][:native_text]
    assert_equal false, rows[1][:has_images]
    assert_equal "prefix", rows[2][:native_text]
    assert_match(/\AText cut at 256 kB/, rows[2][:native_reason])
    assert_equal "damaged stream", rows[3][:native_reason]
    assert_equal "the text output limit was reached", rows[4][:native_reason]
    assert_equal [ "recovered 6", "recovered 7", "recovered 8" ], rows.last(3).pluck(:native_text)
  end

  test "info batch and singleton reads share one shrinking document deadline" do
    calls = []
    info = ->(path, timeout:) {
      assert_equal "document.pdf", path
      assert_equal 30, timeout
      @now += 5
      { pages: 4 }
    }
    read = ->(_path, first, last, timeout:) {
      calls << [ first, last, timeout ]
      if first != last
        @now += 60
        [ page(1), timed_out(2), timed_out(3), timed_out(4) ]
      else
        @now += 10
        [ page(first) ]
      end
    }

    result = PdfText.stub(:info, info) do
      PdfText.stub(:pages, read) { @file.send(:read_pdf, "document.pdf", @deadline) }
    end

    assert_equal [ [ 1, 4, 60 ], [ 3, 3, 35 ], [ 4, 4, 25 ], [ 2, 2, 15 ] ], calls
    assert_equal [ 1, 2, 3, 4 ], result[:pages].pluck(:page_number)
    assert_equal %w[text text text text], result[:pages].pluck(:native_status)
  end

  test "recovery stops below the minimum and marks every unattempted timeout row too long" do
    calls = []
    read = ->(_path, first, last, timeout:) {
      calls << [ first, last, timeout ]
      if first != last
        @now = 97
        [ page(1), timed_out(2), timed_out(3), timed_out(4) ]
      else
        @now = 98.01
        [ page(first, text: "healthy neighbour") ]
      end
    }

    rows = PdfText.stub(:pages, read) { read_batch(1..4) }

    assert_equal [ [ 1, 4, 60 ], [ 3, 3, 3 ] ], calls
    assert_equal %w[text skipped text skipped], rows.pluck(:native_status)
    assert_equal "healthy neighbour", rows[2][:native_text]
    [ rows[1], rows[3] ].each do |row|
      assert_equal FieldFile::PdfExtraction::TOO_LONG, row[:native_reason]
    end
  end

  test "no singleton starts when the initial batch exhausts the document deadline" do
    calls = 0
    read = ->(*) {
      calls += 1
      @now = 100
      [ page(1), timed_out(2), timed_out(3) ]
    }

    rows = PdfText.stub(:pages, read) { read_batch(1..3) }

    assert_equal 1, calls
    assert_equal %w[text skipped skipped], rows.pluck(:native_status)
    assert_equal "page 1", rows[0][:native_text]
    assert rows.drop(1).all? { it[:native_reason] == FieldFile::PdfExtraction::TOO_LONG }
  end

  test "an initially disallowed batch starts no native call" do
    @now = 98.01
    rows = PdfText.stub(:pages, ->(*) { flunk "native call below minimum" }) { read_batch(1..3) }

    assert_equal [ 1, 2, 3 ], rows.pluck(:page_number)
    assert_equal %w[skipped skipped skipped], rows.pluck(:native_status)
    assert rows.all? { it[:native_reason] == FieldFile::PdfExtraction::TOO_LONG }
  end

  test "singleton exceptions affect only their page and do not stop remaining candidates" do
    [ Imprimatur::Error, Errno::EIO, IOError ].each do |error_class|
      calls = []
      read = ->(_path, first, last, timeout:) {
        calls << [ first, last ]
        if first != last
          [ page(1), timed_out(2), timed_out(3), timed_out(4), timed_out(5) ]
        elsif first == 3
          raise error_class, "singleton failed"
        elsif first == 4
          [ timed_out(4) ]
        else
          [ page(first, text: "recovered #{first}") ]
        end
      }

      rows = PdfText.stub(:pages, read) { read_batch(1..5) }

      assert_equal [ [ 1, 5 ], [ 3, 3 ], [ 4, 4 ], [ 5, 5 ], [ 2, 2 ] ], calls
      assert_equal [ 1, 2, 3, 4, 5 ], rows.pluck(:page_number)
      assert_equal %w[text text failed skipped text], rows.pluck(:native_status)
      assert_equal "page 1", rows[0][:native_text]
      assert_equal "recovered 2", rows[1][:native_text]
      assert_includes rows[2][:native_reason], "singleton failed"
      assert_equal timed_out(4)[:reason], rows[3][:native_reason]
      assert_equal "recovered 5", rows[4][:native_text]
    end
  end

  test "only exact upstream timeout reasons on unread rows trigger recovery" do
    # v0.6.1 ae9f851: isolation/stream.rs, protocol.rs and error.rs.
    reasons = [
      "the document exceeds the time limit",
      "the document exceeds the render worker wall time limit",
      "the document exceeds the PDF worker limit limit"
    ]
    reasons.each do |reason|
      calls = []
      pages = [
        page(1, reason: reason), page(2, status: "empty", text: "", reason: reason),
        page(3, status: "failed", reason: reason),
        page(4, status: "skipped", reason: "#{reason} extra"),
        page(5, status: "skipped", reason: reason)
      ]
      read = ->(_path, first, last, timeout:) {
        calls << [ first, last ]
        first == last ? [ page(first) ] : pages
      }

      rows = PdfText.stub(:pages, read) { read_batch(1..5) }

      assert_equal [ [ 1, 5 ], [ 5, 5 ] ], calls
      assert_equal %w[text empty failed skipped text], rows.pluck(:native_status)
      assert_equal "#{reason} extra", rows[3][:native_reason]
    end
  end

  test "recovered truncated text replaces its slot and still passes through the joined text cap" do
    prefix = "é" * (PdfText::MAX_PAGE_BYTES / 2)
    read = ->(_path, first, last, timeout:) {
      if first != last
        [ page(1, text: prefix, truncated: true) ] + (2..9).map { timed_out(it) }
      else
        [ page(first, text: prefix, truncated: true) ]
      end
    }

    rows = PdfText.stub(:pages, read) { read_batch(1..9) }
    joined, cut = @file.send(:joined_text, rows)

    assert_equal (1..9).to_a, rows.pluck(:page_number)
    assert rows.all? { it[:native_text].bytesize == PdfText::MAX_PAGE_BYTES }
    assert rows.all? { it[:native_reason].start_with?("Text cut at") }
    assert cut
    assert_operator joined.bytesize, :<=, FieldFile::PdfExtraction::MAX_JOINED_BYTES
    assert joined.valid_encoding?
  end

  private

  def read_batch(numbers)
    @file.send(:read_batch, "document.pdf", numbers.to_a, @deadline)
  end

  def page(number, status: "text", text: "page #{number}", reason: nil, truncated: false, images: nil)
    { page: number, status: status, text: text, reason: reason, truncated: truncated, images: images }
  end

  def timed_out(number)
    page(number, status: "skipped", text: "", reason: "the document exceeds the time limit")
  end

end
