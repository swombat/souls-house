# Giving one line to the right person: the transcriber heard Anna's sentence
# as Daniel's. The line is addressed as for a text correction
# (FieldRecording::LineCorrection): its timed-word positions, or a supplied
# turn's index, with the text it read and the transcript revision the page
# was shown. Anything changed since is refused rather than moving whatever now
# sits at those positions.
#
# Only the speaker label moves. Words, timings and text stay as they are.
module FieldRecording::LineSpeaker

  Stale = FieldRecording::LineCorrection::Stale
  Invalid = FieldRecording::LineCorrection::Invalid

  module_function

  # Every entry from the line's first timed word to its last, spacing
  # included, takes `label`. A displayed line may span two labels the page
  # shows as one person; both move. Returns the new list.
  def reassign_words(words, first:, last:, was:, label:)
    first = Integer(first, exception: false)
    last = Integer(last, exception: false)
    timed = words.each_index.reject { |n| words[n]["k"] == "s" }
    raise Stale unless first && last && first >= 0 && first <= last && last < timed.size

    from = timed[first]
    to = timed[last]
    text = words[from..to].map { |word| word["t"] }.join
    raise Stale unless normalise(text) == normalise(was)

    words.each_with_index.map { |word, n| n.between?(from, to) ? word.merge("spk" => label) : word }
  end

  def reassign_turn(turns, index:, was:, label:)
    index = Integer(index, exception: false)
    raise Stale unless index && index >= 0 && index < turns.size
    raise Stale unless normalise(turns[index]["t"]) == normalise(was)

    turns.each_with_index.map { |turn, n| n == index ? turn.merge("spk" => label) : turn }
  end

  # A label for someone the transcriber didn't separate. In the transcriber's
  # own shape, so it reads as "Speaker N" until a person names it, on a
  # supplied transcript as well (FieldRecordingSpeaker::GENERIC_LABEL).
  def new_label(taken)
    taken = taken.to_set
    (0..999).each do |n|
      label = "speaker_#{n}"
      return label unless taken.include?(label)
    end
    raise Invalid, "This recording has too many speakers."
  end

  def normalise(text) = FieldRecording::LineCorrection.normalise(text)

end
