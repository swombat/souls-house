# Reads a PDF with the Poppler tools already in the image (poppler-utils):
# pdfinfo for the page count and encryption, pdftotext for each page's text
# layer. Nothing here sends anything anywhere.
#
# Every call is bounded: wall-clock time (`timeout`, then SIGKILL), address
# space and file size (`prlimit`), and the text read back. Arguments go to the
# process as an argv array, never through a shell. Output files live in a
# temporary directory that is removed afterwards.
module PdfText

  class Error < StandardError; end
  # Opening the file needs a password. Permission flags alone (no copying,
  # no printing) do not stop Poppler reading the text and are not this.
  class Encrypted < Error; end
  # Not a PDF Poppler can open, or one with no pages.
  class Unreadable < Error; end
  # A command was killed for time, memory or output size, or exited badly.
  class CommandFailed < Error; end

  INFO_TIMEOUT = 30
  BATCH_TIMEOUT = 60
  PAGE_TIMEOUT = 20
  MEMORY_LIMIT = 1.gigabyte
  # Per page: a page's text layer above this is cut off at this many bytes.
  MAX_PAGE_BYTES = 256.kilobytes
  # What one page alone may write before pdftotext is stopped; a page that
  # passes this is recorded as failed rather than cut.
  MAX_SINGLE_PAGE_OUTPUT = 4 * MAX_PAGE_BYTES
  BATCH_PAGES = 25
  STDERR_LIMIT = 500

  module_function

  # => { pages: Integer, permissions_only: true|false }
  def info(path)
    stdout, stderr, status = run([ "pdfinfo", path.to_s ], timeout: INFO_TIMEOUT)
    unless status.success?
      raise Encrypted, "The PDF needs a password to open" if stderr.include?("Incorrect password")
      raise Unreadable, "Not a PDF the house can open"
    end

    fields = stdout.scrub.lines.to_h { |line| line.split(":", 2).map(&:strip) }
    pages = Integer(fields["Pages"].to_s, exception: false).to_i
    raise Unreadable, "The PDF has no pages" unless pages.positive?

    { pages: pages, permissions_only: fields["Encrypted"].to_s.start_with?("yes") }
  end

  # The text layer of pages first..last, one String per page (possibly
  # empty). Read in one pdftotext run; Poppler ends every page with a form
  # feed, so the run splits into exactly last - first + 1 pages or is refused.
  def pages(path, first, last, timeout: BATCH_TIMEOUT, max_bytes: MAX_PAGE_BYTES * (last - first + 1))
    count = last - first + 1
    text = pdftotext(path, first, last, timeout: timeout, max_bytes: max_bytes)
    parts = text.split("\f", -1)
    parts.pop if parts.last == ""
    raise CommandFailed, "Expected #{count} pages, read #{parts.size}" unless parts.size == count

    parts.map { |page| clean(page) }
  end

  def page(path, number)
    pages(path, number, number, timeout: PAGE_TIMEOUT, max_bytes: MAX_SINGLE_PAGE_OUTPUT).first
  end

  def pdftotext(path, first, last, timeout:, max_bytes:)
    Dir.mktmpdir("pdftext") do |dir|
      out = File.join(dir, "out.txt")
      _stdout, stderr, status = run(
        [ "pdftotext", "-q", "-enc", "UTF-8", "-f", first.to_s, "-l", last.to_s, path.to_s, out ],
        timeout: timeout, max_file_bytes: max_bytes
      )
      raise CommandFailed, failure(status, stderr) unless status.success? && File.exist?(out)

      File.binread(out, max_bytes)
    end
  end

  def run(command, timeout:, max_file_bytes: 0)
    limits = [ "prlimit", "--as=#{MEMORY_LIMIT}", "--fsize=#{max_file_bytes}", "--" ]
    Open3.capture3("timeout", "-k", "5", timeout.to_s, *limits, *command)
  rescue Errno::ENOENT => e
    raise CommandFailed, "Missing tool: #{e.message}"
  end

  def failure(status, stderr)
    reason = case status.exitstatus
    when 124, 137 then "took too long"
    when nil then "was stopped"
    else stderr.to_s.scrub.squish.last(STDERR_LIMIT).presence || "exited #{status.exitstatus}"
    end
    "pdftotext #{reason}"
  end

  # UTF-8, no NULs (Postgres text can't hold them), trailing space trimmed,
  # and capped per page.
  def clean(page)
    text = page.dup.force_encoding(Encoding::UTF_8).scrub("�").delete("\u0000")
    text = text.byteslice(0, MAX_PAGE_BYTES).scrub("") if text.bytesize > MAX_PAGE_BYTES
    text.rstrip
  end

end
