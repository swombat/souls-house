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

  # Both recognition gates open for the block: the house flag and retention
  # in ENV, pyannote "configured", and the account setting on.
  def with_recognition(account)
    previous = ENV.to_h.slice("SOULSHOUSE_FIELD_VOICEPRINTS", "SOULSHOUSE_BACKUP_RETENTION_DAYS")
    ENV["SOULSHOUSE_FIELD_VOICEPRINTS"] = "on"
    ENV["SOULSHOUSE_BACKUP_RETENTION_DAYS"] = "30"
    account.update!(recognise_voices: true)
    PyannoteClient.stub(:api_key, "pk_test") { yield }
  ensure
    %w[SOULSHOUSE_FIELD_VOICEPRINTS SOULSHOUSE_BACKUP_RETENTION_DAYS].each { |key| ENV[key] = previous[key] }
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

  def store_print!(voice, print: "PRINT-#{SecureRandom.hex(4)}")
    voice.with_lock do
      generation = voice.print_generation + 1
      voice.update_columns(print_generation: generation)
      FieldVoiceprint.create!(field_voice: voice, account: voice.account, print:, generation:, sample_ms: 12_000,
        consented_at: Time.current, consent_text_version: FieldVoiceprints::CONSENT_TEXT_VERSION)
    end
  end

  # Stands in for PyannoteClient.
  class FakePyannote

    attr_reader :voiceprint_calls, :identify_calls

    def initialize(jobs: {})
      @jobs = jobs
      @voiceprint_calls = []
      @identify_calls = []
    end

    def voiceprint(url:) = (@voiceprint_calls << url) && "vp_job"
    def identify(**kwargs) = (@identify_calls << kwargs) && "id_job"
    def job(id) = @jobs.fetch(id)

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
