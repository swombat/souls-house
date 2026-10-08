# Turning an identify result into recognitions (spec §9, "Diarization when
# both run"; Mira's B, provisionally, as an experiment, not a calibration).
# Scribe's words and speakers are the user's view and are never changed.
#
# Everything is computed on time intervals, never word midpoints:
#
# - a speaker's speech is the union of their word intervals;
# - crosstalk is removed: wherever words from two Scribe speakers overlap, and
#   wherever two or more identify segments are active at once (every overlap,
#   nested ones included);
# - a voice covers the part of the remaining speech that intersects segments
#   matched to it; speech in unmatched segments, or in no segment, stays as
#   unknown and counts towards the total only.
#
# A speaker is recognised as a voice only if that voice covers at least 70% of
# their remaining speech and no other voice covers any of it.
module FieldVoiceprints::Matching

  COVERAGE = 0.7
  # Anything outside these is malformed output and ignored, never scaled:
  # a timestamp past a week can't belong to one recording, and confidence is
  # a percentage.
  MAX_SECONDS = 7 * 24 * 3600
  CONFIDENCE_RANGE = (0..100)

  module_function

  # valid_labels: {label => [voice_id, generation]} for labels still usable.
  # Returns {scribe_label => {voice_id:, generation:, confidence:}}.
  def recognitions(words, output, valid_labels)
    output = {} unless output.is_a?(Hash)
    segments = Array(output["identification"]).filter_map do |segment|
      next unless segment.is_a?(Hash)

      from, to = ms(segment["start"]), ms(segment["end"])
      next unless from && to && to > from

      { s: from, e: to, match: segment["match"].is_a?(String) ? segment["match"] : nil, diar: segment["diarizationSpeaker"] }
    end
    confidences = confidence_table(output)
    return {} unless confidences # malformed scores: no guess from this output at all
    spoken = words.select { |word| word["k"] == "w" && word["spk"] && word["e"].to_i > word["s"].to_i }

    excluded = union(crowded(segments.map { |seg| [ seg[:s], seg[:e] ] }) +
                     crowded_between_speakers(spoken))

    spoken.group_by { |word| word["spk"] }.filter_map do |label, own|
      speech = subtract(union(own.map { |word| [ word["s"], word["e"] ] }), excluded)
      total = length(speech)
      next if total.zero?

      covered = Hash.new(0)
      weighted = Hash.new(0.0)
      segments.each do |segment|
        next unless segment[:match] && valid_labels.key?(segment[:match])

        time = length(intersect(speech, [ [ segment[:s], segment[:e] ] ]))
        next if time.zero?

        covered[segment[:match]] += time
        weighted[segment[:match]] += time * confidences.dig(segment[:diar], segment[:match]).to_f
      end
      next unless covered.size == 1

      match, time = covered.first
      next if time < COVERAGE * total

      voice_id, generation = valid_labels.fetch(match)
      [ label, { voice_id:, generation:, confidence: (weighted[match] / time).round } ]
    end.to_h
  end

  # Where two or more intervals are active at once.
  def crowded(intervals)
    events = intervals.flat_map { |from, to| [ [ from, 1 ], [ to, -1 ] ] }.sort_by { |at, delta| [ at, delta ] }
    active = 0
    start = nil
    result = []
    events.each do |at, delta|
      active += delta
      if active >= 2 && start.nil?
        start = at
      elsif active < 2 && start
        result << [ start, at ] if at > start
        start = nil
      end
    end
    result
  end

  # Where words from two different Scribe speakers overlap.
  def crowded_between_speakers(spoken)
    per_speaker = spoken.group_by { |word| word["spk"] }.values.map { |own| union(own.map { |w| [ w["s"], w["e"] ] }) }
    crowded(per_speaker.flatten(1))
  end

  def union(intervals)
    intervals.sort.each_with_object([]) do |(from, to), merged|
      if merged.any? && from <= merged.last[1]
        merged.last[1] = [ merged.last[1], to ].max
      else
        merged << [ from, to ]
      end
    end
  end

  def intersect(a, b)
    result = []
    i = j = 0
    while i < a.size && j < b.size
      from = [ a[i][0], b[j][0] ].max
      to = [ a[i][1], b[j][1] ].min
      result << [ from, to ] if to > from
      a[i][1] < b[j][1] ? i += 1 : j += 1
    end
    result
  end

  def subtract(a, b)
    a.flat_map do |from, to|
      pieces = [ [ from, to ] ]
      b.each do |cut_from, cut_to|
        pieces = pieces.flat_map do |p_from, p_to|
          next [ [ p_from, p_to ] ] if cut_to <= p_from || cut_from >= p_to

          [ ([ p_from, cut_from ] if cut_from > p_from), ([ cut_to, p_to ] if cut_to < p_to) ].compact
        end
      end
      pieces
    end
  end

  def length(intervals) = intervals.sum { |from, to| to - from }

  # {diarization speaker => {label => score}}, or nil if any score present is
  # not a real number in range: a result that scores in arrays, hashes,
  # booleans or infinities isn't one to guess from.
  def confidence_table(output)
    Array(output["voiceprints"]).each_with_object({}) do |row, table|
      next unless row.is_a?(Hash) && row["confidence"].is_a?(Hash)
      return nil unless row["confidence"].values.all? { |value| confidence?(value) }

      table[row["speaker"]] = row["confidence"]
    end
  end

  # A real number in range. Strings, booleans, arrays and hashes are not.
  def confidence?(value)
    value.is_a?(Numeric) && !value.is_a?(Complex) && value.to_f.finite? && CONFIDENCE_RANGE.cover?(value.to_f)
  end

  def ms(seconds)
    value = Float(seconds, exception: false)
    return nil unless value&.finite? && value >= 0 && value <= MAX_SECONDS

    (value * 1000).round
  end

end
