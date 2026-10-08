# "Suggested from what's said" (spec §8): one small model call per recording
# proposes who the unnamed speakers might be, each with a line they said. The
# model's answer is only a proposal; validation is ours. A suggestion survives
# only if its quote is really in that speaker's words and its name is one this
# Field already knows or that appears in the title, note or transcript. A
# failure here does nothing visible and refunds nothing.
module FieldRecordings
  class SuggestSpeakersJob < ApplicationJob

    queue_as :default

    MODEL = "google/gemini-2.5-flash"
    MAX_TRANSCRIPT_CHARS = 20_000
    SOURCE = "utility"

    SYSTEM = <<~PROMPT.freeze
      You read a transcript whose speakers are labelled S1, S2 and so on, and suggest who
      an unlabelled speaker might be, but only when what is said makes it clear (someone
      is addressed by name and answers, someone introduces themself, someone talks about
      "my" thing that the notes tie to a person). For each suggestion give the speaker
      label, the name, and one short quote copied exactly from that speaker's own lines
      that supports it. Suggest nothing when you are not sure. Never guess from voice or style.
    PROMPT

    SCHEMA = {
      type: "object",
      additionalProperties: false,
      required: [ "suggestions" ],
      properties: {
        suggestions: {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: %w[speaker name quote],
            properties: { speaker: { type: "string" }, name: { type: "string" }, quote: { type: "string" } }
          }
        }
      }
    }.freeze

    def perform(recording_id, inference: UtilityInference)
      recording = FieldRecording.kept.find_by(id: recording_id)
      return unless recording&.ready?

      unnamed = recording.speakers.reject { |speaker| speaker.field_voice&.kept? }
      return if unnamed.empty?

      answer = inference.structured(model: MODEL, effort: "low", system: SYSTEM, state: state_for(recording), schema: SCHEMA)
      store(recording, validated(recording, answer))
    rescue UtilityInference::Error
      nil
    end

    private

    def state_for(recording)
      {
        title: recording.title,
        note: recording.note.to_s,
        names_this_field_knows: known_names(recording),
        transcript: labelled_transcript(recording).truncate(MAX_TRANSCRIPT_CHARS)
      }
    end

    def labelled_transcript(recording)
      labels = recording.speakers.to_h { |speaker| [ speaker.label, "S#{speaker.position + 1}" ] }
      FieldRecording::Transcript.render(recording.transcript_words || [], labels)
    end

    def known_names(recording)
      account = recording.account
      (account.field_voices.kept.pluck(:name) +
        account.users.map { |user| user.full_name.presence || user.email_address.split("@").first }).uniq
    end

    # [{speaker:, name:, quote:, at_ms:, voice:}] that pass every check.
    def validated(recording, answer)
      suggestions = answer.is_a?(Hash) ? Array(answer["suggestions"]) : []
      by_tag = recording.speakers.index_by { |speaker| "S#{speaker.position + 1}" }
      known = known_names(recording)
      haystack = normalise([ recording.title, recording.note, recording.transcript_text ].join(" "))

      suggestions.filter_map do |suggestion|
        next unless suggestion.is_a?(Hash)

        speaker = by_tag[suggestion["speaker"].to_s.strip]
        name = suggestion["name"].to_s.squish
        quote = suggestion["quote"].to_s.squish
        next if speaker.nil? || speaker.field_voice&.kept? || name.blank? || name.length > FieldVoice::MAX_NAME_LENGTH
        next if quote.length < 3 || quote.length > 300
        next unless known.any? { |known_name| known_name.casecmp?(name) } || haystack.include?(normalise(name))

        at_ms = quote_position(recording.transcript_words || [], speaker.label, quote)
        next unless at_ms

        voice = recording.account.field_voices.kept.named_like(name).first
        { speaker:, name: voice&.name || name, quote:, at_ms:, voice: }
      end.uniq { |suggestion| suggestion[:speaker].id }
    end

    # Where the quote starts within one of this speaker's turns, or nil when
    # the speaker never said it.
    def quote_position(words, label, quote)
      target = normalise(quote)
      FieldRecording::Transcript.turns(words).each do |turn|
        next unless turn[:spk] == label

        spoken = turn[:words].reject { |word| word["k"] == "a" }
        text = +""
        starts = []
        spoken.each do |word|
          starts << [ text.length, word["s"] ]
          text << word["t"]
        end
        normalised, map = normalise_with_map(text)
        index = normalised.index(target)
        next unless index

        original = map[index]
        return starts.select { |offset, _| offset <= original }.last&.last || turn[:s]
      end
      nil
    end

    def store(recording, suggestions)
      return if suggestions.empty?

      recording.with_lock do
        next unless recording.kept? && recording.ready?

        suggestions.each do |suggestion|
          speaker = suggestion[:speaker].reload
          next if speaker.field_voice&.kept?

          speaker.update!(suggested_voice: suggestion[:voice], suggested_name: suggestion[:name],
            suggestion_quote: suggestion[:quote], suggestion_quote_ms: suggestion[:at_ms],
            suggestion_source: SOURCE, suggested_at: Time.current)
        end
        recording.touch
      end
    end

    def normalise(text) = text.to_s.downcase.gsub(/[^\p{L}\p{N}]+/, " ").squish

    # The normalised text, and for each of its characters the index of the
    # character it came from in the original.
    def normalise_with_map(text)
      out = +""
      map = []
      pending_space = false
      text.each_char.with_index do |char, index|
        if char.match?(/[\p{L}\p{N}]/)
          if pending_space && !out.empty?
            out << " "
            map << index
          end
          pending_space = false
          out << char.downcase
          map << index
        else
          pending_space = true
        end
      end
      [ out, map ]
    end

  end
end
