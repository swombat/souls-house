require "test_helper"

# One application-level contract against the published native worker. Detailed
# retry scheduling and budget edge cases belong to Imprimatur's own suite.
class FieldFilePdfTimeoutIntegrationTest < ActiveSupport::TestCase

  test "upstream recovery reads healthy neighbours through one thin adapter call" do
    Tempfile.create([ "timeout-neighbours", ".pdf" ]) do |file|
      file.binmode
      file.write(slow_middle_pdf)
      file.flush
      native = Imprimatur.method(:pdf_pages)
      calls = []
      read = ->(path, **options) {
        calls << options
        native.call(path, **options)
      }
      deadline = FieldFile::PdfExtraction::Deadline.new(
        -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, 10)

      with_constant(PdfText, :BATCH_TIMEOUT, 0.5) do
        # Without the new option, the initial attempt cannot reach page 3.
        initial = native.call(file.path, first_page: 1, last_page: 3, timeout: 0.5)
        assert_equal %w[text skipped skipped], initial[:pages].pluck(:status),
          "the synthetic middle page must actually time out"

        rows = Imprimatur.stub(:pdf_pages, read) do
          FieldFile.new.send(:read_batch, file.path, [ 1, 2, 3 ], deadline)
        end
        assert_equal 1, calls.size, "the application must not implement retries"
        assert_equal 0.5, calls.sole[:batch_timeout]
        assert_operator calls.sole[:timeout], :>, calls.sole[:batch_timeout]
        assert_operator calls.sole[:timeout], :<=, 10
        assert_equal PdfText::MAX_PAGE_BYTES * 3, calls.sole[:max_output_bytes]
        assert_equal PdfText::MEMORY_LIMIT, calls.sole[:memory_bytes]
        assert_equal [ 1, 2, 3 ], rows.pluck(:page_number)
        assert_equal "Healthy first page", rows.first[:native_text]
        assert_equal "Healthy third page", rows.last[:native_text]
        assert_equal "text", rows.last[:native_status]
        assert_equal "skipped", rows.second[:native_status]
        assert rows.second[:native_reason].present?
        assert_operator deadline.remaining, :>, 0
      end
    end
  end

  test "successive batches receive only the shrinking original document allowance" do
    now = 0
    deadline = FieldFile::PdfExtraction::Deadline.new(-> { now }, 100)
    calls = []
    read = ->(_path, first, last, timeout:) {
      calls << [ first, last, timeout ]
      now += 40
      (first..last).map { { page: it, status: "text", text: "page #{it}" } }
    }
    reader = FieldFile.new

    PdfText.stub(:pages, read) do
      3.times { |index| reader.send(:read_batch, "document.pdf", [ index + 1 ], deadline) }
      rows = reader.send(:read_batch, "document.pdf", [ 4 ], deadline)
      assert_equal "skipped", rows.sole[:native_status]
      assert_equal FieldFile::PdfExtraction::TOO_LONG, rows.sole[:native_reason]
    end
    assert_equal [ [ 1, 1, 100 ], [ 2, 2, 60 ], [ 3, 3, 20 ] ], calls
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

  def slow_middle_pdf
    # Compact nested forms perform 100^5 graphics operations without allocating
    # a huge content stream in the Rails test process (upstream's fixture shape).
    forms = %w[B C D].map { "/#{it} Do\n" * 100 } << ("q Q\n" * 100)
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 /MediaBox [0 0 612 792] /Resources " \
        "<< /Font << /F1 6 0 R >> /XObject << /A 10 0 R /B 11 0 R /C 12 0 R /D 13 0 R >> >> >>"
    ]
    3.times do |index|
      objects << "<< /Type /Page /Parent 2 0 R /Contents #{7 + index} 0 R >>"
    end
    objects << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    [
      "BT /F1 12 Tf 50 700 Td (Healthy first page) Tj ET",
      "/A Do\n" * 100,
      "BT /F1 12 Tf 50 700 Td (Healthy third page) Tj ET"
    ].each do |stream|
      objects << "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
    end
    forms.each do |stream|
      objects << "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792] /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
    end
    pdf = "%PDF-1.4\n".b
    offsets = []
    objects.each_with_index do |object, index|
      offsets << pdf.bytesize
      pdf << "#{index + 1} 0 obj\n" << object << "\nendobj\n"
    end
    start = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
    offsets.each { pdf << "%010d 00000 n \n" % it }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\nstartxref\n#{start}\n%%EOF\n"
  end

end
