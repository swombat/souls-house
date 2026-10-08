# Scribe's words, compacted for storage, and what is derived from them (spec
# §5, §7): speakers with talk time and a listening clip, and the plain-text
# rendering residents read. Scribe's speaker labels are kept as they are.
module FieldRecording::Transcript

  TURN_GAP_MS = 1_500
  CLIP_ISOLATION_MS = 1_000
  CLIP_MAX_MS = 5_000
  KINDS = { "word" => "w", "spacing" => "s", "audio_event" => "a" }.freeze

  module_function

  # [{s:, e:, t:, k:, spk:}] with ms integers. Unknown entry types are dropped.
  def compact(words)
    Array(words).filter_map do |word|
      next unless word.is_a?(Hash) && KINDS.key?(word["type"])

      {
        "s" => ms(word["start"]), "e" => ms(word["end"]), "t" => word["text"].to_s,
        "k" => KINDS[word["type"]], "spk" => word["speaker_id"].presence
      }
    end
  end

  # Turns: consecutive spoken entries by one speaker, broken by a change of
  # speaker or a long gap. Spacing joins words inside a turn.
  def turns(words)
    words.each_with_object([]) do |word, turns|
      next if word["k"] == "s" && turns.empty?

      last = turns.last
      if word["k"] == "s"
        last[:words] << word
      elsif last && last[:spk] == word["spk"] && word["s"] - last[:e] <= TURN_GAP_MS
        last[:words] << word
        last[:e] = [ last[:e], word["e"] ].max
      else
        turns << { spk: word["spk"], s: word["s"], e: word["e"], words: [ word ] }
      end
    end
  end

  # [{label:, position:, talk_ms:, clip_start_ms:, clip_end_ms:}] in order of
  # first appearance.
  def speakers(words)
    spoken = words.select { |word| word["k"] == "w" && word["spk"] }
    all_turns = turns(words).select { |turn| turn[:spk] }

    spoken.map { |word| word["spk"] }.uniq.each_with_index.map do |label, position|
      own = all_turns.select { |turn| turn[:spk] == label }
      clip = clip_for(own, spoken.reject { |word| word["spk"] == label })
      {
        label:, position:,
        talk_ms: spoken.select { |word| word["spk"] == label }.sum { |word| word["e"] - word["s"] },
        clip_start_ms: clip&.dig(:s),
        clip_end_ms: clip && [ clip[:e], clip[:s] + CLIP_MAX_MS ].min
      }
    end
  end

  # The longest turn with nobody else speaking within a second of it, or the
  # longest turn when none is that clean.
  def clip_for(own_turns, others)
    by_length = own_turns.sort_by { |turn| -(turn[:e] - turn[:s]) }
    by_length.find do |turn|
      others.none? { |word| word["e"] > turn[:s] - CLIP_ISOLATION_MS && word["s"] < turn[:e] + CLIP_ISOLATION_MS }
    end || by_length.first
  end

  # Plain text for residents and search: "[mm:ss] Name: words". Names come from
  # the caller; slice A uses "Speaker N" (only human-set names ever appear).
  def render(words, names)
    turns(words).map do |turn|
      text = turn[:words].map { |word| word["k"] == "a" ? "(#{word['t'].delete('()')})" : word["t"] }.join.squeeze(" ").strip
      next if text.empty?

      speaker = names.fetch(turn[:spk], "Unattributed")
      "[#{timestamp(turn[:s])}] #{speaker}: #{text}"
    end.compact.join("\n")
  end

  def timestamp(ms)
    total = ms / 1000
    hours, rest = total.divmod(3600)
    minutes, seconds = rest.divmod(60)
    hours.positive? ? format("%d:%02d:%02d", hours, minutes, seconds) : format("%02d:%02d", minutes, seconds)
  end

  def ms(seconds) = (seconds.to_f * 1000).round

end
