# "Suggested from what's said" (spec §8): one small model call per recording
# proposes who the unnamed speakers might be, each with a line they said. The
# model's answer is only a proposal; validation is ours:
#
# - the call is gated (FieldSuggestions.enabled?) and claimed once, durably,
#   before it is made: duplicate jobs never call again, whatever the result;
# - only speakers no person has decided anything about (named, un-named,
#   dismissed) are considered, and their decision generation is snapshotted
#   before the call; a suggestion is stored only if it hasn't moved since;
# - the name must be one this Field knows, or appear as whole words in the
#   title, note or transcript;
# - the quote must be found in that speaker's own words, and what is stored and
#   shown is the source excerpt itself, with its true time, not the model's
#   rendering of it.
#
# A failure does nothing visible and refunds nothing.
module FieldRecordings
  class SuggestSpeakersJob < ApplicationJob

    queue_as :default

    MODEL = "google/gemini-2.5-flash"
    MAX_TRANSCRIPT_CHARS = 20_000
    MAX_NAMES = 50
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
      return unless FieldSuggestions.enabled?

      recording, snapshot = claim(recording_id)
      return unless recording

      answer = begin
        inference.structured(model: MODEL, effort: "low", system: SYSTEM, state: state_for(recording), schema: SCHEMA)
      rescue UtilityInference::Error
        recording.update_columns(suggestions_state: "failed")
        return
      end
      store(recording, validated(recording, answer), snapshot)
    end

    private

    # Under the recording lock: claim the one call, and snapshot each unnamed
    # speaker's decision generation. nil when there is nothing to do.
    def claim(recording_id)
      recording = FieldRecording.find_by(id: recording_id)
      return unless recording

      recording.with_lock do
        next nil unless recording.kept? && recording.ready? && recording.suggestions_state.nil?

        # Only speakers no person has made any decision about. A dismissal, a
        # name or a correction back to "Speaker N" is final for suggestions.
        unnamed = recording.speakers.select { |speaker| !speaker.field_voice&.kept? && speaker.decision_generation.zero? }
        if unnamed.empty?
          recording.update_columns(suggestions_state: "done")
          next nil
        end

        recording.update_columns(suggestions_state: "claimed")
        [ recording, unnamed.to_h { |speaker| [ speaker.id, speaker.decision_generation ] } ]
      end
    end

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

    # Only names that could be the answer: this Field's voices and members,
    # capped. Nothing else about the account is sent.
    def known_names(recording)
      account = recording.account
      (account.field_voices.kept.order(updated_at: :desc).limit(MAX_NAMES).pluck(:name) +
        account.users.map { |user| user.full_name.presence || user.email_address.split("@").first })
        .uniq.first(MAX_NAMES)
    end

    def validated(recording, answer)
      suggestions = answer.is_a?(Hash) ? Array(answer["suggestions"]) : []
      by_tag = recording.speakers.index_by { |speaker| "S#{speaker.position + 1}" }
      known = known_names(recording).map { |name| tokens(name) }
      haystack = tokens([ recording.title, recording.note, recording.transcript_text ].join(" "))

      suggestions.filter_map do |suggestion|
        next unless suggestion.is_a?(Hash)

        speaker = by_tag[suggestion["speaker"].to_s.strip]
        name = suggestion["name"].to_s.squish
        name_tokens = tokens(name)
        next if speaker.nil? || speaker.field_voice&.kept? || name_tokens.empty? || name.length > FieldVoice::MAX_NAME_LENGTH
        next unless known.include?(name_tokens) || contains_sequence?(haystack, name_tokens)

        excerpt = source_excerpt(recording.transcript_words || [], speaker.label, suggestion["quote"].to_s)
        next unless excerpt

        { speaker:, name: canonical_name(recording, name), quote: excerpt[:text], at_ms: excerpt[:at_ms] }
      end.uniq { |suggestion| suggestion[:speaker].id }
    end

    def canonical_name(recording, name)
      recording.account.field_voices.kept.named_like(name).pick(:name) || name
    end

    # The speaker's own words that the quote matches (compared on letters and
    # digits only), returned as the source text itself with its start time.
    def source_excerpt(words, label, quote)
      target = tokens(quote)
      return nil if target.size < 2 || quote.length > 300

      FieldRecording::Transcript.turns(words).each do |turn|
        next unless turn[:spk] == label

        spoken = turn[:words].select { |word| word["k"] == "w" }
        spoken_tokens = spoken.map { |word| tokens(word["t"]) }
        flat = spoken_tokens.each_with_index.flat_map { |list, index| list.map { |token| [ token, index ] } }
        start = (0..(flat.size - target.size)).find { |i| flat[i, target.size].map(&:first) == target }
        next unless start

        first_word = flat[start].last
        last_word = flat[start + target.size - 1].last
        text = spoken[first_word..last_word].map { |word| word["t"] }.join(" ").squish
        return { text: text.truncate(300), at_ms: spoken[first_word]["s"] }
      end
      nil
    end

    def store(recording, suggestions, snapshot)
      recording.with_lock do
        if recording.kept? && recording.ready?
          suggestions.each do |suggestion|
            speaker = suggestion[:speaker].reload
            generation = snapshot[speaker.id]
            next if generation.nil? || speaker.decision_generation != generation || speaker.field_voice&.kept?

            speaker.update!(suggested_voice: nil, suggested_name: suggestion[:name], suggestion_quote: suggestion[:quote],
              suggestion_quote_ms: suggestion[:at_ms], suggestion_source: SOURCE, suggested_at: Time.current,
              suggestion_generation: generation)
          end
        end
        recording.update_columns(suggestions_state: "done")
        recording.touch
      end
    end

    def tokens(text) = text.to_s.downcase.scan(/[\p{L}\p{N}]+/)

    def contains_sequence?(haystack, needle)
      return false if needle.empty? || needle.size > haystack.size

      haystack.each_cons(needle.size).any? { |window| window == needle }
    end

  end
end
