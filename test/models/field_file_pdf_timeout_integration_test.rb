require "test_helper"
require "zlib"

# Exercise the published native worker, not a mocked timeout. The middle page
# has millions of harmless graphics operations; the two neighbours have text.
class FieldFilePdfTimeoutIntegrationTest < ActiveSupport::TestCase

  test "a real batch timeout recovers the healthy later page within the original document deadline" do
    Tempfile.create([ "timeout-neighbours", ".pdf" ]) do |file|
      file.binmode
      file.write(slow_middle_pdf)
      file.flush

      timeout = 0.1
      original = PdfText.pages(file.path, 1, 3, timeout: timeout)
      assert_equal %w[text skipped skipped], original.map { it[:status] },
        "fixture must really hit the batch timeout, not a decompression or output limit"

      deadline = FieldFile::PdfExtraction::Deadline.new(
        -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, 10)
      with_constant(PdfText, :BATCH_TIMEOUT, timeout) do
        rows = FieldFile.new.send(:read_batch, file.path, [ 1, 2, 3 ], deadline)
        assert_equal [ 1, 2, 3 ], rows.map { it[:page_number] }
        assert_equal "Healthy first page", rows.first[:native_text]
        assert_equal "Healthy third page", rows.last[:native_text]
        assert_equal "text", rows.last[:native_status]
        assert_operator deadline.remaining, :>, 0
      end
    end
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
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"
    ]
    3.times do |index|
      objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 6 0 R >> >> /Contents #{7 + index} 0 R >>"
    end
    objects << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    [
      "BT /F1 12 Tf 50 700 Td (Healthy first page) Tj ET",
      "q Q\n" * 5_000_000,
      "BT /F1 12 Tf 50 700 Td (Healthy third page) Tj ET"
    ].each do |stream|
      compressed = Zlib::Deflate.deflate(stream)
      objects << "<< /Length #{compressed.bytesize} /Filter /FlateDecode >>\nstream\n".b + compressed + "\nendstream"
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
