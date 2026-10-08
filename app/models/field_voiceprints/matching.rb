# Turning an identify result into recognitions (spec §9, "Diarization when
# both run"; Mira's B, provisionally, as an experiment, not a calibration).
# Scribe's words and speakers are the user's view and are never changed. Work
# only on non-overlapping speech: words that overlap another speaker's words
# and stretches where identify segments overlap are left out, so crosstalk
# can't inflate coverage. A Scribe speaker is recognised as a voice only if at
# least 70% of their remaining word time lies in segments matched to that
# voice and none lies in a segment matched to another. Otherwise nothing.
module FieldVoiceprints::Matching

  COVERAGE = 0.7

  module_function

  # valid_labels: {label => [voice_id, generation]} for labels still usable.
  # Returns {scribe_label => {voice_id:, generation:, confidence:}}.
  def recognitions(words, output, valid_labels)
    segments = Array(output["identification"]).filter_map do |segment|
      next unless segment.is_a?(Hash)

      { s: ms(segment["start"]), e: ms(segment["end"]), match: segment["match"], diar: segment["diarizationSpeaker"] }
    end
    overlaps = overlap_intervals(segments)
    confidences = confidence_table(output)
    spoken = words.select { |word| word["k"] == "w" && word["spk"] && word["e"] > word["s"] }
    crosstalk = crosstalk_words(spoken)

    spoken.reject { |word| crosstalk.include?(word.object_id) }.group_by { |word| word["spk"] }.filter_map do |label, own|
      total = 0
      covered = Hash.new(0)
      weighted = Hash.new(0.0)
      own.each do |word|
        middle = (word["s"] + word["e"]) / 2
        next if overlaps.any? { |from, to| middle >= from && middle < to }

        length = word["e"] - word["s"]
        total += length
        segment = segments.find { |candidate| middle >= candidate[:s] && middle < candidate[:e] }
        next unless segment && segment[:match] && valid_labels.key?(segment[:match])

        covered[segment[:match]] += length
        weighted[segment[:match]] += length * confidences.dig(segment[:diar], segment[:match]).to_f
      end
      next if total.zero? || covered.size != 1

      match, time = covered.first
      next if time < COVERAGE * total

      voice_id, generation = valid_labels.fetch(match)
      [ label, { voice_id:, generation:, confidence: (weighted[match] / time).round } ]
    end.to_h
  end

  def overlap_intervals(segments)
    sorted = segments.sort_by { |segment| segment[:s] }
    sorted.each_cons(2).filter_map do |first, second|
      [ second[:s], [ first[:e], second[:e] ].min ] if second[:s] < first[:e]
    end
  end

  def crosstalk_words(spoken)
    marked = Set.new
    sorted = spoken.sort_by { |word| word["s"] }
    sorted.each_with_index do |word, index|
      sorted[(index + 1)..].each do |other|
        break if other["s"] >= word["e"]
        next if other["spk"] == word["spk"]

        marked << word.object_id << other.object_id
      end
    end
    marked
  end

  def confidence_table(output)
    Array(output["voiceprints"]).each_with_object({}) do |row, table|
      next unless row.is_a?(Hash) && row["confidence"].is_a?(Hash)

      table[row["speaker"]] = row["confidence"]
    end
  end

  def ms(seconds) = (seconds.to_f * 1000).round

end
