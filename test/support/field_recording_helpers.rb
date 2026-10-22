require "stringio"

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
    cutover = Setting.instance.field_naming_cutover_at
    ENV["VOICE_EMBEDDING_URL"] = "http://souls-house-voice-embeddings:8000"
    ENV["VOICE_EMBEDDING_TOKEN"] = "t" * 32
    account.update!(recognise_voices: true)
    Setting.instance.update!(field_naming_cutover_at: 1.day.ago)
    yield
  ensure
    %w[VOICE_EMBEDDING_URL VOICE_EMBEDDING_TOKEN].each { |key| ENV[key] = previous[key] }
    Setting.instance.update_columns(field_naming_cutover_at: cutover) if previous
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
    vector = Array.new(192) { noise * (random.rand - 0.5) }
    vector[axis] += 1.0
    norm = Math.sqrt(vector.sum { |value| value * value })
    vector.map { |value| value / norm }
  end

  # A stored print, active unless active: false. Validation is stamped with
  # the account's cohort digest, so every validated print in the account is
  # restamped as the cohort grows (as a real validation run would). Its fixture
  # testimony is real persisted, audio-backed, exact-digest confirmation, not
  # sample_count metadata that could bypass the production confirmed-set gate.
  def store_print!(voice, vector: voice_vector(voice.id % 100), active: true, profile: FieldVoiceprints::Profiles::ECAPA)
    samples = 2.times.map do |index|
      sample = voice.samples.find_or_initialize_by(source_identifier: "synthetic-print-fixture-#{index}")
      sample.assign_attributes(account: voice.account, source_session: "synthetic-print-#{voice.id}-#{index}",
        embedding: JSON.generate(vector), profile:, speech_ms: 6_000, label_origin: "human", learning_status: "learned")
      unless sample.audio.attached?
        # Six seconds of synthetic PCM; no provider or real person's recording.
        pcm = [ (voice.id * 2 + index) % 32_768 ].pack("v") * (16_000 * 6)
        wav = "RIFF".b + [ 36 + pcm.bytesize ].pack("V") + "WAVEfmt " +
          [ 16, 1, 1, 16_000, 32_000, 2, 16 ].pack("VvvVVvv") + "data" + [ pcm.bytesize ].pack("V") + pcm
        sample.content_sha256 = Digest::SHA256.hexdigest(wav)
        sample.audio.attach(io: StringIO.new(wav), filename: "synthetic.wav", content_type: "audio/wav")
      end
      sample.source_sha256 = sample.content_sha256
      sample.save!
      sample.update!(source_digest: FieldVoiceSamples::Uploads.source_digest(sample))
      sample.update!(eligible: true, confirmed_digest: sample.source_digest,
        confirmed_by: voice.account.users.first || users(:user_1), confirmed_at: Time.current)
      assert sample.source_current?
      assert sample.manually_confirmed?
      sample
    end
    print = voice.with_lock do
      generation = voice.print_generation + 1
      voice.update_columns(print_generation: generation)
      row = FieldVoiceprint.find_or_initialize_by(field_voice: voice)
      row.update!(account: voice.account, print: JSON.generate(vector), generation:,
        profile:, sample_count: samples.size, recording_count: samples.map(&:source_group_key).uniq.size,
        speech_ms: samples.sum(&:speech_ms), sample_digest: FieldVoiceprints::Learning.digest(samples), validated: active)
      row
    end
    restamp_cohort!(voice.account)
    print.reload
  end

  # Synthetic extraction fixture, but confirmation goes through the real review
  # operation with the current persisted source digest and an attributed user.
  def confirmed_recording_sample!(voice, recording:, vector:, profile: FieldVoiceprints::Profiles::ECAPA, speech_ms: 5_000)
    holder = FieldRecordingSpeaker.create!(field_recording: recording, field_voice: voice, naming_source: "human",
      label: "sample-#{SecureRandom.hex(4)}", position: 50 + recording.speakers.count)
    segments = [ [ 0, speech_ms ] ]
    sample = FieldVoiceSample.create!(account: voice.account, field_voice: voice, field_recording_speaker: holder,
      field_recording: recording, embedding: JSON.generate(vector), speech_ms:, profile:, label_origin: "human",
      eligible: false, source_segments: segments, source_digest: FieldVoiceSample.source_digest_for(holder, segments))
    assert holder.review_sample!(sample:, digest: sample.source_digest, by: users(:user_1), included: true)
    assert sample.reload.manually_confirmed?
    sample
  end

  def restamp_cohort!(account)
    digest = FieldVoiceprints::Cohort.digest(FieldVoiceprints::Cohort.prints(account))
    FieldVoiceprint.where(account:, validated: true).update_all(validated_digest: digest)
  end

  # Stands in for FieldVoiceprints::VoiceEmbeddings. `vectors` maps a call
  # index (or :default) to the embedding returned; records each call.
  class FakeVoiceEmbeddings

    attr_reader :calls

    def initialize(vectors = {}, profile: FieldVoiceprints::Profiles::ECAPA, fail_with: nil)
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
