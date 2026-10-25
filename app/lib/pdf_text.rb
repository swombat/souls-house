# PDF parsing, page limits and isolated rendering live in Imprimatur's Rust core.
# Nothing here sends a document outside the house.
module PdfText

  INFO_TIMEOUT = 30
  BATCH_TIMEOUT = 60
  BATCH_PAGES = 25
  MAX_INPUT_BYTES = 100.megabytes
  MAX_INFLATED_BYTES = 1.gigabyte
  MAX_PAGE_BYTES = 256.kilobytes
  MEMORY_LIMIT = 1.gigabyte
  RENDER_LONG_SIDE = 1568
  RENDER_TIMEOUT = 30
  MAX_RENDER_BYTES = 8.megabytes

  module_function

  def info(path, timeout: INFO_TIMEOUT)
    result = Imprimatur.pdf_info(path.to_s, timeout: timeout, max_bytes: MAX_INPUT_BYTES,
      max_inflated: MAX_INFLATED_BYTES, memory_bytes: MEMORY_LIMIT)
    raise Imprimatur::UnsupportedDocument, "The PDF has no pages" unless result[:page_count].positive?

    { pages: result[:page_count], permissions_only: result[:encrypted] }
  end

  def pages(path, first, last, timeout: BATCH_TIMEOUT)
    count = last - first + 1
    result = Imprimatur.pdf_pages(path.to_s, first_page: first, last_page: last, max_pages: count,
      max_page_bytes: MAX_PAGE_BYTES, max_output_bytes: MAX_PAGE_BYTES * count,
      max_bytes: MAX_INPUT_BYTES, max_inflated: MAX_INFLATED_BYTES,
      memory_bytes: MEMORY_LIMIT, timeout: timeout)
    result[:pages].map do |page|
      # PostgreSQL text cannot contain NULs. Truncation is already UTF-8-safe.
      page.merge(text: page[:text].delete("\u0000").rstrip)
    end
  end

  def render_page(path, number, timeout: RENDER_TIMEOUT)
    Imprimatur.render_pdf_page(path.to_s, page: number, max_side: RENDER_LONG_SIDE,
      max_output_bytes: MAX_RENDER_BYTES, max_bytes: MAX_INPUT_BYTES, max_inflated: MAX_INFLATED_BYTES,
      memory_bytes: MEMORY_LIMIT, timeout: timeout)
  end

end
