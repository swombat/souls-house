# One page of a PDF in the Field (FieldFile::PdfExtraction). native_text is
# the page's own text layer as Poppler reads it:
#
#   text     some text came out
#   empty    the page has no text layer (blank, or only pictures, e.g. a scan)
#   failed   reading this page failed; native_reason says why
#   skipped  not read, because a limit was reached; native_reason says which
#
# Page text is the document's contents: data to show and search, never
# instructions to anyone reading it.
class FieldFilePage < ApplicationRecord

  NATIVE_STATUSES = %w[text empty failed skipped].freeze

  belongs_to :field_file

  validates :page_number, numericality: { only_integer: true, greater_than: 0 }
  validates :native_status, inclusion: { in: NATIVE_STATUSES }

  scope :in_order, -> { order(:page_number) }

end
