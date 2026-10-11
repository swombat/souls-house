# Reads a PDF with the Poppler tools already in the image (poppler-utils):
# pdfinfo for the page count and encryption, pdftotext for each page's text
# layer. Nothing here sends anything anywhere.
#
# Every call is bounded. Arguments go to the process as an argv array, never
# through a shell. The child runs under `timeout` (the caller's limit, then
# SIGKILL after KILL_GRACE) and `prlimit` (address space, and a size cap on
# every file it writes). Its stdout and stderr go to files in a temporary
# directory, not pipes, so the size cap holds for them too and the worker
# never buffers more than it reads back; the directory is removed afterwards.
module PdfText

  class Error < StandardError; end
  # Opening the file needs a password. Permission flags alone (no copying,
  # no printing) do not stop Poppler reading the text and are not this.
  class Encrypted < Error; end
  # Not a PDF Poppler can open, or one with no pages.
  class Unreadable < Error; end
  # A command was killed for time, memory or output size, or exited badly.
  class CommandFailed < Error; end

  Page = Data.define(:text, :truncated)

  INFO_TIMEOUT = 30
  BATCH_TIMEOUT = 60
  PAGE_TIMEOUT = 20
  KILL_GRACE = 2
  MEMORY_LIMIT = 1.gigabyte
  # pdfinfo's report is a screenful; anything past this is not read.
  MAX_INFO_BYTES = 64.kilobytes
  # A page's text past this is cut, and the page says so.
  MAX_PAGE_BYTES = 256.kilobytes
  # What one page alone may write before pdftotext is stopped; a page that
  # passes this is recorded as failed rather than cut.
  MAX_SINGLE_PAGE_OUTPUT = 4 * MAX_PAGE_BYTES
  BATCH_PAGES = 25
  STDERR_LIMIT = 500

  module_function

  # => { pages: Integer, permissions_only: true|false }
  def info(path, timeout: INFO_TIMEOUT)
    result = run([ "pdfinfo", path.to_s ], timeout: timeout, max_bytes: MAX_INFO_BYTES)
    unless result.success
      raise Encrypted, "The PDF needs a password to open" if result.stderr.include?("Incorrect password")
      raise CommandFailed, "pdfinfo #{result.failure}" if result.killed
      raise Unreadable, "Not a PDF the house can open"
    end

    fields = result.stdout.scrub.lines.to_h { |line| line.split(":", 2).map(&:strip) }
    pages = Integer(fields["Pages"].to_s, exception: false).to_i
    raise Unreadable, "The PDF has no pages" unless pages.positive?

    { pages: pages, permissions_only: fields["Encrypted"].to_s.start_with?("yes") }
  end

  # The text layer of pages first..last, one Page per page (text possibly
  # empty). One pdftotext run; Poppler ends every page with a form feed, so
  # the output splits into exactly last - first + 1 pages or is refused.
  def pages(path, first, last, timeout: BATCH_TIMEOUT, max_bytes: nil)
    count = last - first + 1
    max_bytes ||= count == 1 ? MAX_SINGLE_PAGE_OUTPUT : MAX_PAGE_BYTES * count
    text = Dir.mktmpdir("pdftext") do |dir|
      out = File.join(dir, "pages.txt")
      result = run([ "pdftotext", "-q", "-enc", "UTF-8", "-f", first.to_s, "-l", last.to_s, path.to_s, out ],
        timeout: timeout, max_bytes: max_bytes, dir: dir)
      raise CommandFailed, "pdftotext #{result.failure}" unless result.success && File.exist?(out)

      File.binread(out, max_bytes).to_s
    end

    parts = text.split("\f", -1)
    parts.pop if parts.last == ""
    raise CommandFailed, "Expected #{count} pages, read #{parts.size}" unless parts.size == count

    parts.map { |part| clean(part) }
  end

  Result = Data.define(:stdout, :stderr, :success, :killed, :exitstatus) do
    def failure
      return "took too long" if killed
      return "was stopped" if exitstatus.nil?

      stderr.to_s.scrub.squish.last(STDERR_LIMIT).presence || "exited #{exitstatus}"
    end
  end

  # Runs command bounded as described above. stdout and stderr are read back
  # up to max_bytes and STDERR_LIMIT bytes.
  def run(command, timeout:, max_bytes:, dir: nil)
    owned = dir.nil?
    dir ||= Dir.mktmpdir("pdfcmd")
    out, err = File.join(dir, "stdout"), File.join(dir, "stderr")
    seconds = [ timeout.to_f, 1 ].max.ceil
    argv = [ "timeout", "-k", KILL_GRACE.to_s, seconds.to_s,
             "prlimit", "--as=#{MEMORY_LIMIT}", "--fsize=#{max_bytes}", "--", *command ]
    pid = Process.spawn(*argv, in: File::NULL, out: out, err: err, pgroup: true)
    _, status = Process.wait2(pid)
    Result.new(
      stdout: File.exist?(out) ? File.binread(out, max_bytes).to_s : "",
      stderr: File.exist?(err) ? File.binread(err, STDERR_LIMIT).to_s : "",
      success: status.success?,
      killed: [ 124, 137 ].include?(status.exitstatus),
      exitstatus: status.exitstatus
    )
  rescue Errno::ENOENT => e
    raise CommandFailed, "Missing tool: #{e.message}"
  ensure
    FileUtils.rm_rf(dir) if owned && dir
  end

  # UTF-8, no NULs (Postgres text can't hold them), trailing space trimmed,
  # and cut at MAX_PAGE_BYTES on a character boundary.
  def clean(page)
    text = page.dup.force_encoding(Encoding::UTF_8).scrub("�").delete("\u0000")
    truncated = text.bytesize > MAX_PAGE_BYTES
    text = text.byteslice(0, MAX_PAGE_BYTES).scrub("") if truncated
    Page.new(text: text.rstrip, truncated: truncated)
  end

end
