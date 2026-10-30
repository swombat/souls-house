# Transcribes a PDF's scanned or nearly empty pages (FieldOcr), one page at a
# time, keeping each transcription apart from the page's own text.
#
# Every call is reserved first (FieldOcr.reserve!), and a page's result is
# stored before its call is settled, so a page with a settled call always
# has its text and is never paid for twice. Before each image leaves, the
# house checks again that OCR is still on, that the file is still kept and
# that there is time left; the call gets at most that time. An image not
# sent gives its reservation back. Only pages never tried are tried: a
# failed or skipped page stays so until someone retries it on purpose. A
# limit reached (the file's pages, the account's day, the house's budget,
# the time budget, OCR turned off) marks the remaining pages skipped with
# the reason.
#
# The file stays "pending" (no summary) while a page is held by another
# worker; this job looks again once that worker's reservation would have
# lapsed. When nothing is left, it is "done" and summarised.
module FieldFile::PdfOcr

  extend ActiveSupport::Concern

  OCR_TIME_BUDGET = 10.minutes
  CALL_TIMEOUT = 60
  TURNED_OFF = "Transcription was turned off".freeze

  def transcribe_pdf!(inference: UtilityInference, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    # A file waiting on OCR always gets to an end, even if OCR was turned
    # off meanwhile (its pages then say so); any other file only while on.
    return false unless kept? && pdf_readable? && (pdf_transcription_pending? || FieldOcr.eligible?(self))

    deadline = FieldFile::PdfExtraction::Deadline.new(clock, OCR_TIME_BUDGET)
    todo = pages.reload.select { FieldOcr.candidate?(it) && it.model_status.nil? }
    if todo.any?
      file.open { |tempfile| transcribe_pages(tempfile.path, todo, deadline, inference) }
    end
    return false unless FieldFile.kept.exists?(id) # discarded meanwhile: nothing more to do

    finish_transcription
  end

  private

  # Anything still untried was held by another worker: stay pending and look
  # again when its reservation would have lapsed. Otherwise done.
  def finish_transcription
    held = pages.reload.any? { FieldOcr.candidate?(it) && it.model_status.nil? }
    restate_pdf!(ocr: held ? "pending" : "done")
    broadcast_refresh
    if held
      FieldFiles::OcrPdfJob.set(wait: FieldOcr::IN_FLIGHT).perform_later(id)
    else
      enqueue_summary
    end
    true
  end

  def transcribe_pages(path, todo, deadline, inference)
    stop = nil
    todo.each do |page|
      next mark_model(page, "skipped", stop) if stop

      break if discarded_now?
      next mark_model(page, "skipped", stop = TURNED_OFF) unless FieldOcr.eligible?(self)

      render_timeout = deadline.allow(PdfText::RENDER_TIMEOUT)
      next mark_model(page, "skipped", stop = FieldFile::PdfExtraction::TOO_LONG) unless render_timeout && deadline.allow(CALL_TIMEOUT)

      call = begin
        FieldOcr.reserve!(self, page.page_number)
      rescue FieldOcr::LimitReached => e
        next mark_model(page, "skipped", stop = e.message)
      end
      next unless call.is_a?(FieldOcrCall) # :done or :in_flight: nothing to pay for here

      stop = transcribe_page(path, page, call, render_timeout, deadline, inference)
    end
  end

  # => a reason to stop the rest, or nil.
  def transcribe_page(path, page, call, render_timeout, deadline, inference)
    png = begin
      PdfText.render_page(path, page.page_number, timeout: render_timeout)
    rescue Imprimatur::Error, SystemCallError, IOError, ArgumentError => e
      call.release!
      mark_model(page, "failed", "The page could not be turned into an image (#{e.message})")
      return nil
    end

    # Checked again now the image exists: rendering takes time, and OCR may
    # have been turned off or the file discarded meanwhile.
    if discarded_now?
      call.release!
      return "discarded"
    end
    unless FieldOcr.eligible?(self)
      call.release!
      mark_model(page, "skipped", TURNED_OFF)
      return TURNED_OFF
    end
    timeout = deadline.allow(CALL_TIMEOUT)
    unless timeout
      call.release!
      mark_model(page, "skipped", FieldFile::PdfExtraction::TOO_LONG)
      return FieldFile::PdfExtraction::TOO_LONG
    end

    result = begin
      FieldOcr.transcribe(png, page_number: page.page_number, page_count: pdf_page_count, timeout: timeout, inference: inference)
    rescue UtilityInference::Error
      call.fail!
      mark_model(page, "failed", "The transcription failed")
      return nil
    end

    reason = "The transcription was cut short (#{result[:cut_reason]})" if result[:cut]
    mark_model(page, result[:status], reason, text: result[:text])
    call.settle!(result[:usage], upstream_id: result[:id])
    nil
  end

  def discarded_now? = !FieldFile.kept.exists?(id)

  def mark_model(page, status, reason = nil, text: nil)
    page.update_columns(model_status: status, model_text: text, model_reason: reason&.truncate(500),
      model_id: (FieldOcr::MODEL if status.in?(%w[text empty])), updated_at: Time.current)
  end

end
