# Transcribes a PDF's scanned or nearly empty pages (FieldOcr), one page at a
# time, keeping each transcription apart from the page's own text.
#
# Every call is reserved first (FieldOcr.reserve!), and a page's result is
# stored before its call is settled, so a page with a settled call always
# has its text and is never paid for twice. Only pages never tried are
# tried: a failed or skipped page stays so until someone retries it on
# purpose. A limit reached (the file's pages, the account's day, the house's
# budget, the time budget) marks the remaining pages skipped with the reason.
module FieldFile::PdfOcr

  extend ActiveSupport::Concern

  OCR_TIME_BUDGET = 10.minutes
  CALL_TIMEOUT = 60

  def transcribe_pdf!(inference: UtilityInference, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    return false unless kept? && pdf_readable? && FieldOcr.eligible?(self)

    deadline = FieldFile::PdfExtraction::Deadline.new(clock, OCR_TIME_BUDGET)
    todo = pages.reload.select { FieldOcr.candidate?(it) && it.model_status.nil? }
    file.open { |tempfile| transcribe_pages(tempfile.path, todo, deadline, inference) } if todo.any?

    restate_pdf!(ocr: "done")
    broadcast_refresh
    enqueue_summary
    true
  end

  private

  def transcribe_pages(path, todo, deadline, inference)
    stop = nil
    todo.each do |page|
      next mark_model(page, "skipped", stop) if stop

      render_timeout = deadline.allow(PdfText::RENDER_TIMEOUT)
      next mark_model(page, "skipped", stop = FieldFile::PdfExtraction::TOO_LONG) unless render_timeout && deadline.allow(CALL_TIMEOUT)

      call = begin
        FieldOcr.reserve!(self, page.page_number)
      rescue FieldOcr::LimitReached => e
        next mark_model(page, "skipped", stop = e.message)
      end
      next unless call.is_a?(FieldOcrCall) # :done or :in_flight: nothing to pay for here

      transcribe_page(path, page, call, render_timeout, inference)
    end
  end

  def transcribe_page(path, page, call, render_timeout, inference)
    png = begin
      PdfText.render_page(path, page.page_number, timeout: render_timeout)
    rescue PdfText::CommandFailed => e
      call.release!
      return mark_model(page, "failed", "The page could not be turned into an image (#{e.message})")
    end

    result = begin
      FieldOcr.transcribe(png, page_number: page.page_number, page_count: pdf_page_count, inference: inference)
    rescue UtilityInference::Error
      call.fail!
      return mark_model(page, "failed", "The transcription failed")
    end

    reason = "The transcription was cut short (#{result[:cut_reason]})" if result[:cut]
    mark_model(page, result[:status], reason, text: result[:text])
    call.settle!(result[:usage], upstream_id: result[:id])
  end

  def mark_model(page, status, reason = nil, text: nil)
    page.update_columns(model_status: status, model_text: text, model_reason: reason&.truncate(500),
      model_id: (FieldOcr::MODEL if status.in?(%w[text empty])), updated_at: Time.current)
  end

end
