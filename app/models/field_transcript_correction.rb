# One batch of corrections to a recording's transcript, or the undo of one
# (FieldRecording::TranscriptCorrection). `edits` keeps the full original
# entries, not just their text, so an undo restores them exactly.
#
# Scribe: [{ "from", "to" (indices into the pre-edit words, spacing
# included), "at" (where the replacement sits in the result), "before":
# [entries], "after": [entries] }]. Supplied: [{ "turn", "before": turn,
# "after": turn }].
class FieldTranscriptCorrection < ApplicationRecord

  include ObfuscatesId

  KINDS = %w[correction undo].freeze

  belongs_to :account
  belongs_to :field_recording
  belongs_to :corrected_by, polymorphic: true, optional: true
  belongs_to :undoes, class_name: "FieldTranscriptCorrection", optional: true

  validates :kind, inclusion: { in: KINDS }

  scope :latest_first, -> { order(revision: :desc) }

  def correction? = kind == "correction"
  def undo? = kind == "undo"

  def corrector_name
    case corrected_by
    when User then corrected_by.full_name.presence || corrected_by.email_address.split("@").first
    when Agent then corrected_by.name
    end
  end

  # "cinquante → soixante-dix" per edit, for the page's history line.
  def summary_lines
    edits.map do |edit|
      before = text_of(edit["before"])
      after = text_of(edit["after"])
      "#{before.presence || '∅'} → #{after.presence || '∅'}"
    end
  end

  def as_history_json
    {
      id: to_param, kind:, revision:, by: corrector_name, at: created_at.iso8601,
      undone: undone_at.present?, changes: summary_lines.first(5), change_count: edits.size
    }
  end

  private

  def text_of(value)
    entries = value.is_a?(Array) ? value : [ value ].compact
    entries.map { |entry| entry["t"].to_s }.join.squish.truncate(80)
  end

end
