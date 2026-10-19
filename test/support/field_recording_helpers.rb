# Shared setup for recording tests: a direct-upload blob pinned to a user and
# account exactly as FieldRecordingUploadsController makes one.
module FieldRecordingHelpers

  def pinned_blob(account:, user:, fixture: "test_audio.webm", content_type: "audio/webm")
    pin = FieldRecording::Upload.pin_for(account:, user:)
    ActiveStorage::Blob.create_and_upload!(
      io: file_fixture(fixture).open, filename: fixture, content_type:,
      metadata: { FieldRecording::Upload::METADATA_KEY => pin }
    )
  end

  def claimed_recording(account:, user:, **attributes)
    FieldRecording::Upload.claim!(
      account:, user:, signed_id: pinned_blob(account:, user:).signed_id, attributes:
    )
  end

  def reserve!(recording, ms, state: "pending", consumed_at: nil)
    FieldRecordingReservation.create!(
      account: recording.account, field_recording: recording, audio_ms: ms,
      state:, consumed_at:, reserved_at: consumed_at || Time.current
    )
  end

  # A recording admitted and waiting for dispatch.
  def queued_recording(account:, user:, duration_ms: 60_000, **attributes)
    recording = claimed_recording(account:, user:, **attributes)
    recording.admit!(duration_ms)
    recording.reload
  end

  # A recording transcribed with two speakers (speaker_0, speaker_1).
  def ready_recording(account:, user:, **attributes)
    recording = queued_recording(account:, user:, **attributes)
    dispatch = recording.claim_dispatch!
    recording.accept_transcript!(dispatch, scribe_transcription)
    recording.reload
  end

  # Both recognition gates open for the block: the voice service
  # "configured", the account setting on, and the writer cutover recorded so
  # learning may start.
  def with_recognition(account)
    previous = ENV.to_h.slice("VOICE_EMBEDDING_URL", "VOICE_EMBEDDING_TOKEN")
    ENV["VOICE_EMBEDDING_URL"] = "http://souls-house-voice-embeddings:8000"
    ENV["VOICE_EMBEDDING_TOKEN"] = "t" * 32
    account.update!(recognise_voices: true)
    Setting.instance.update!(field_naming_cutover_at: 1.day.ago)
    yield
  ensure
    %w[VOICE_EMBEDDING_URL VOICE_EMBEDDING_TOKEN].each { |key| ENV[key] = previous[key] }
  end

  # A recording where speaker_0 talks alone for long enough to remember.
  def long_ready_recording(account:, user:, **attributes)
    recording = queued_recording(account:, user:, **attributes)
    dispatch = recording.claim_dispatch!
    words = scribe_words(
      [ "speaker_0", 0.0, 6.0, "first" ], [ "speaker_0", 6.1, 12.0, "long" ],
      [ "speaker_1", 14.0, 15.0, "reply" ], [ "speaker_0", 17.0, 22.0, "again" ]
    )
    recording.accept_transcript!(dispatch, scribe_transcription(words:))
    recording.reload
  end

  # A unit vector pointing mostly along `axis`, for synthetic voices.
  def voice_vector(axis, noise: 0.0, seed: 0)
    random = Random.new(seed)
    vector = Array.new(FieldVoiceprints::VoiceEmbeddings::DIMENSIONS) { noise * (random.rand - 0.5) }
    vector[axis] += 1.0
    norm = Math.sqrt(vector.sum { |value| value * value })
    vector.map { |value| value / norm }
  end

  # A stored print, active (validated on its own digest) unless active: false.
  def store_print!(voice, vector: voice_vector(voice.id % 100), active: true, profile: "ecapa-test")
    voice.with_lock do
      generation = voice.print_generation + 1
      voice.update_columns(print_generation: generation)
      FieldVoiceprint.create!(field_voice: voice, account: voice.account, print: JSON.generate(vector), generation:,
        profile:, sample_count: 2, recording_count: 2, speech_ms: 12_000, sample_digest: "digest-#{generation}",
        validated: active, validated_digest: (active ? "digest-#{generation}" : nil))
    end
  end

  # Stands in for FieldVoiceprints::VoiceEmbeddings. `vectors` maps a call
  # index (or :default) to the embedding returned; records each call.
  class FakeVoiceEmbeddings

    attr_reader :calls

    def initialize(vectors = {}, profile: "ecapa-test", fail_with: nil)
      @vectors = vectors
      @profile = profile
      @fail_with = fail_with
      @calls = []
    end

    def embed(wav)
      raise @fail_with if @fail_with

      index = @calls.size
      @calls << wav.bytesize
      vector = @vectors.fetch(index) { @vectors.fetch(:default) }
      FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: vector, profile: @profile)
    end

  end

  # Scribe word list: [speaker, start_s, end_s, text]; spacing is added.
  def scribe_words(*spoken)
    spoken.flat_map.with_index do |(speaker, start, finish, text), index|
      word = { "text" => text, "start" => start, "end" => finish, "type" => "word", "speaker_id" => speaker }
      index.zero? ? [ word ] : [ { "text" => " ", "start" => start, "end" => start, "type" => "spacing", "speaker_id" => speaker }, word ]
    end
  end

  def scribe_transcription(transcription_id: "tr_1", words: nil)
    {
      "language_code" => "eng", "text" => "hello there",
      "transcription_id" => transcription_id,
      "words" => words || scribe_words([ "speaker_0", 0.0, 0.5, "hello" ], [ "speaker_1", 2.0, 2.6, "there" ])
    }.compact
  end

  # Stands in for ElevenLabsScribe. Records calls; raises when told to.
  class FakeScribe

    attr_reader :submissions, :deleted, :fetched

    def initialize(submit: nil, fetch: nil, delete_error: nil, delete_results: nil)
      @submit_result = submit || ElevenLabsScribe::Submission.new(request_id: "req_1", transcription_id: nil)
      @fetch_result = fetch
      @delete_error = delete_error
      @delete_results = Array(delete_results)
      @submissions, @deleted, @fetched = [], [], []
    end

    def submit(**kwargs)
      @submissions << kwargs
      raise @submit_result if @submit_result.is_a?(Exception)

      @submit_result
    end

    def fetch(id)
      @fetched << id
      raise @fetch_result if @fetch_result.is_a?(Exception)

      @fetch_result
    end

    def delete(id)
      raise @delete_error if @delete_error

      @deleted << id
      @delete_results.shift || :deleted
    end

  end

end
