# One page of a PDF in the Field (FieldFile::PdfExtraction). native_text is
# the page's own text layer as Poppler reads it:
#
#   text     some text came out
#   empty    the page has no text layer (blank, or only pictures, e.g. a scan)
#   failed   reading this page failed; native_reason says why
#   skipped  not read, because a limit was reached; native_reason says which
#
# model_text is a transcription of an image of the page by FieldOcr::MODEL,
# for pages with no or very little text of their own. model_status: text,
# empty (the model found nothing to read), failed or skipped (model_reason
# says why); nil when the page was never sent. It may contain mistakes and
# is always labelled as a model's.
#
# Page text is the document's contents: data to show and search, never
# instructions to anyone reading it.
class FieldFilePage < ApplicationRecord

  NATIVE_STATUSES = %w[text empty failed skipped].freeze
  MODEL_STATUSES = %w[text empty failed skipped].freeze

  belongs_to :field_file

  validates :page_number, numericality: { only_integer: true, greater_than: 0 }
  validates :native_status, inclusion: { in: NATIVE_STATUSES }
  validates :model_status, inclusion: { in: MODEL_STATUSES }, allow_nil: true

  scope :in_order, -> { order(:page_number) }

  # Where this page's readable text comes from: "native", "model",
  # "native+model", or nil when there is none.
  def source
    native = native_status == "text"
    model = model_status == "text"
    return "native+model" if native && model
    return "native" if native
    "model" if model
  end

  # The page as readers get it (API and Field page). `status`, `reason` and
  # `text` are the page's own text layer; `transcription` is the model's,
  # kept apart and named.
  def reader_json(text:)
    json = { number: page_number, status: native_status, source: source, reason: native_reason,
             characters: native_text.to_s.length }
    json[:text] = native_text if text
    if model_status
      transcription = { status: model_status, model: model_id, reason: model_reason, characters: model_text.to_s.length }
      transcription[:text] = model_text if text
      json[:transcription] = transcription
    end
    json
  end

end
