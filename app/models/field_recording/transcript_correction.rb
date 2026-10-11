# Correcting a transcript's words (conversation WjNZVj), so the Field's copy
# can be the canonical one. A person corrects; residents only ever read the
# corrected text.
#
# Safeguards (Mira's review of the design):
#
# - Every correction and undo names the transcript revision it was made
#   against. Under the recording's lock a stale one is refused (Stale, 409),
#   and the corrected source, the rendered text, the revision and the audit
#   row are written together.
# - Scribe indices are into the exact stored words array, spacing entries
#   included (what the page and the API return). A batch's ranges all refer
#   to the one pre-edit revision: overlaps, and ranges that cross a speaker
#   or turn, are refused, and edits apply from the end.
# - A run collapses into one corrected word keeping the run's outer timing
#   (first start, last end) and marked "c", not each original word's
#   timing. Speaker talk time and listening clips are not recomputed from it.
# - The full original entries are kept, so undo restores timings, spacing and
#   speaker labels exactly. Only the latest batch can be undone (older
#   locators go wrong after later edits), and the undo is itself a row.
# - A correction clears a summary written from the old words, or one being
#   written, and requeues it; the summary store is guarded by revision
#   (FieldSummarizable), so an older in-flight job can't republish the old gist.
module FieldRecording::TranscriptCorrection

  extend ActiveSupport::Concern

  class Invalid < StandardError; end
  class NothingToUndo < StandardError; end

  class Stale < StandardError

    attr_reader :revision

    def initialize(revision)
      @revision = revision
      super("The transcript changed since you loaded it (it is now revision #{revision}). Reload and try again.")
    end

  end

  MAX_EDITS = 50
  MAX_WORD_TEXT = 500

  included do
    has_many :transcript_corrections, class_name: "FieldTranscriptCorrection", dependent: :destroy
  end

  def summary_revision = transcript_revision

  # corrections: Scribe [{ from:, to:, text: }], supplied [{ turn:, text: }].
  # Returns the FieldTranscriptCorrection row.
  def correct_transcript!(revision:, corrections:, by:)
    requeue = false
    row = with_lock do
      check_revision!(revision)
      raise Invalid, "Only a finished transcript can be corrected." unless kept? && ready?

      list = Array(corrections)
      raise Invalid, "Send at least one correction." if list.empty?
      raise Invalid, "At most #{MAX_EDITS} corrections at once." if list.size > MAX_EDITS

      edits = supplied? ? apply_turn_edits!(list) : apply_word_edits!(list)
      requeue = clear_summary_for_new_words!
      record_change!(kind: "correction", base: revision, edits:, by:)
    end
    enqueue_summary if requeue
    row
  end

  # Undoes the latest correction batch, if nothing has changed since.
  def undo_transcript_correction!(revision:, by:)
    requeue = false
    row = with_lock do
      check_revision!(revision)
      last = transcript_corrections.latest_first.first
      raise NothingToUndo, "There is no correction to undo." unless last&.correction? && last.undone_at.nil? &&
        last.revision == transcript_revision

      inverse = supplied? ? undo_turn_edits!(last.edits) : undo_word_edits!(last.edits)
      requeue = clear_summary_for_new_words!
      last.update!(undone_at: Time.current)
      record_change!(kind: "undo", base: revision, edits: inverse, by:, undoes: last)
    end
    enqueue_summary if requeue
    row
  end

  def undoable_correction
    last = transcript_corrections.latest_first.first
    last if last&.correction? && last.undone_at.nil? && last.revision == transcript_revision
  end

  private

  def check_revision!(revision)
    given = Integer(revision.to_s, 10, exception: false)
    raise Invalid, "Send the transcript revision you are correcting." if given.nil?
    raise Stale.new(transcript_revision) unless given == transcript_revision
  end

  def apply_word_edits!(list)
    words = (transcript_words || []).map(&:dup)
    turn_of = FieldRecording::Transcript.turn_indices(words)
    ranges = list.map { |item| word_range(item, words, turn_of) }.sort_by { |range| range[:from] }
    ranges.each_cons(2) do |a, b|
      raise Invalid, "Corrections overlap (#{a[:from]}–#{a[:to]} and #{b[:from]}–#{b[:to]})." if b[:from] <= a[:to]
    end

    ranges.reverse_each { |range| words[range[:from]..range[:to]] = range[:after] }
    shift = 0
    edits = ranges.map do |range|
      at = range[:from] + shift
      shift += range[:after].size - (range[:to] - range[:from] + 1)
      { "from" => range[:from], "to" => range[:to], "at" => at, "before" => range[:before], "after" => range[:after] }
    end
    save_words!(words)
    edits
  end

  def word_range(item, words, turn_of)
    item = item.to_h.stringify_keys
    from = Integer(item["from"].to_s, 10, exception: false)
    to = Integer(item["to"].to_s, 10, exception: false)
    raise Invalid, "Each correction needs from and to (word positions) and text." if from.nil? || to.nil? || !item.key?("text")
    raise Invalid, "Positions #{from}–#{to} are not in this transcript." unless from >= 0 && from <= to && to < words.size

    run = words[from..to]
    raise Invalid, "A correction must start and end on a word, not spacing." if run.first["k"] == "s" || run.last["k"] == "s"
    raise Invalid, "A correction must stay within one speaker's turn." unless turn_of[from..to].uniq.size == 1

    text = item["text"].to_s.squish
    raise Invalid, "A corrected word can be at most #{MAX_WORD_TEXT} characters." if text.length > MAX_WORD_TEXT

    after = text.empty? ? [] : [ { "s" => run.first["s"], "e" => run.last["e"], "t" => text, "k" => "w", "spk" => run.first["spk"], "c" => true } ]
    { from:, to:, before: run, after: }
  end

  def undo_word_edits!(edits)
    words = (transcript_words || []).map(&:dup)
    edits.sort_by { |edit| edit["at"] }.reverse_each do |edit|
      words[edit["at"], edit["after"].size] = edit["before"]
    end
    save_words!(words)
    # The inverse, in the same shape, against the words as they were.
    edits.sort_by { |edit| edit["at"] }.map do |edit|
      from = edit["at"]
      at = edit["from"]
      { "from" => from, "to" => from + edit["after"].size - 1, "at" => at, "before" => edit["after"], "after" => edit["before"] }
    end
  end

  def apply_turn_edits!(list)
    turns = (transcript_turns || []).map(&:dup)
    edits = list.map do |item|
      item = item.to_h.stringify_keys
      index = Integer(item["turn"].to_s, 10, exception: false)
      raise Invalid, "Each correction needs turn (its position) and text." if index.nil? || !item.key?("text")
      raise Invalid, "Turn #{index} is not in this transcript." unless index >= 0 && index < turns.size

      text = item["text"].to_s.strip
      raise Invalid, "A turn can't be emptied; correct it to the words that were said." if text.empty?

      { "turn" => index, "before" => turns[index], "after" => turns[index].merge("t" => text) }
    end
    raise Invalid, "Each turn can be corrected once per batch." if edits.map { |edit| edit["turn"] }.uniq.size != edits.size

    edits.each { |edit| turns[edit["turn"]] = edit["after"] }
    if turns.sum { |turn| turn["t"].to_s.length } > FieldRecording::SuppliedTranscript::MAX_CHARS
      raise Invalid, "The transcript would be longer than #{FieldRecording::SuppliedTranscript::MAX_CHARS} characters."
    end
    save_turns!(turns)
    edits
  end

  def undo_turn_edits!(edits)
    turns = (transcript_turns || []).map(&:dup)
    edits.each { |edit| turns[edit["turn"]] = edit["before"] }
    save_turns!(turns)
    edits.map { |edit| { "turn" => edit["turn"], "before" => edit["after"], "after" => edit["before"] } }
  end

  def save_words!(words)
    self.transcript_words = words
    self.transcript_text = render_transcript_text
    self.transcript_revision = transcript_revision + 1
    save!
  end

  def save_turns!(turns)
    self.transcript_turns = turns
    self.transcript_text = render_transcript_text
    self.transcript_revision = transcript_revision + 1
    save!
  end

  # A summary written from the old words, or being written from them, is
  # stale. Returns whether to requeue (there was one, or one in flight); an
  # unsummarised recording is left to the normal path.
  def clear_summary_for_new_words!
    had = summarized? || summary_claimed_at.present?
    if had
      update_columns(summary_short: nil, summary_long: nil, summarized_at: nil, summary_claimed_at: nil,
        summary_attempts: 0)
    end
    had
  end

  def record_change!(kind:, base:, edits:, by:, undoes: nil)
    transcript_corrections.create!(account:, kind:, base_revision: base, revision: transcript_revision, edits:,
      corrected_by: by, undoes:)
  end

end
