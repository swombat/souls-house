require "test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

# A recording that arrives with its transcript (docs/2026-10-09-field-supplied-
# transcripts.md): the archive import path.
class Api::V1::Field::SuppliedTranscriptsTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers
  include ApiHumanKeyHelpers
  include ActiveJob::TestHelper

  TEXT = "Source: ~/dev/pa/media/audio/2026-10-04_2045_anna.mp3\n\n" \
         "00:00 Daniel: [cutlery clinking]\n00:21 Anna: How am I feeling?\n00:22 Daniel: Mm-hmm.\n"

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
  end

  def import(blob: pinned_blob(account: @account, user: @user), **params)
    post api_v1_field_recordings_path, params: { upload_id: blob.signed_id, **params }, headers: @headers, as: :json
  end

  test "an upload with its transcript lands ready, with provenance, and nothing is reserved or sent" do
    assert_enqueued_jobs 1, only: FieldRecordings::ProbeJob do
      assert_no_enqueued_jobs only: [ FieldRecordings::TranscribeJob, FieldRecordings::IdentifyJob,
                                      FieldRecordings::SuggestSpeakersJob ] do
        import(title: "Anna, evening", transcript_text: TEXT, source_path: "media/recordings/transcripts/2026-10-04_2045_anna.md",
          recorded_at: "2026-10-04T20:45:00+02:00", import_key: "pa:2026-10-04_2045_anna", language_code: "en",
          expected_speakers: 5)
      end
    end
    assert_response :created
    body = response.parsed_body["recording"]
    assert_equal [ "ready", "supplied", "pa:2026-10-04_2045_anna" ], body.values_at("status", "transcript_source", "import_key")
    assert_equal Time.iso8601("2026-10-04T18:45:00Z"), Time.iso8601(body["recorded_at"])
    assert_equal [], body["words"]
    assert_equal [ nil, "Daniel", "Anna", "Daniel" ], body["turns"].map { |turn| turn["spk"] }
    assert_equal %w[Daniel Anna], body["speakers"].map { |speaker| speaker["name"] }
    assert body["speakers"].all? { |speaker| speaker["talk_ms"].nil? && speaker["clip_start_ms"].nil? }
    assert_includes body["transcript_text"], "[00:21] Anna: How am I feeling?"
    assert_not body["retryable"]

    recording = @account.field_recordings.find(body["id"])
    assert_nil recording.reservation
    assert_empty recording.dispatches
    assert_nil recording.expected_speakers, "there is no diarizer to steer"
    assert_equal "en", recording.language_code
    assert_equal "media/recordings/transcripts/2026-10-04_2045_anna.md", recording.source_path
  end

  test "the probe only learns the length of a supplied recording" do
    import(transcript_text: TEXT)
    recording = @account.field_recordings.find(response.parsed_body.dig("recording", "id"))
    FieldRecording::Probe.stub(:duration_ms, 61_000) do
      assert_no_enqueued_jobs(only: FieldRecordings::TranscribeJob) { FieldRecordings::ProbeJob.perform_now(recording.id) }
    end
    recording.reload
    assert_equal [ "ready", 61_000 ], [ recording.status, recording.duration_ms ]
    assert_nil recording.reservation

    FieldRecording::Probe.stub(:duration_ms, nil) { FieldRecordings::ProbeJob.perform_now(recording.id) }
    assert_equal "ready", recording.reload.status, "unreadable audio leaves the transcript standing"
  end

  test "the same import key returns what it made; once deleted, it stays deleted" do
    import(transcript_text: TEXT, import_key: "pa:one")
    first = response.parsed_body.dig("recording", "id")

    second_blob = pinned_blob(account: @account, user: @user)
    assert_no_difference -> { FieldRecording.count } do
      import(blob: second_blob, transcript_text: TEXT, import_key: " pa:one ")
    end
    assert_response :ok
    assert response.parsed_body["existing"]
    assert_equal first, response.parsed_body.dig("recording", "id")
    assert_not ActiveStorage::Attachment.exists?(blob_id: second_blob.id), "left for the orphan sweep"

    get api_v1_field_recordings_path(import_key: "pa:one"), headers: @headers
    assert_equal [ first ], response.parsed_body["recordings"].map { |r| r["id"] }

    delete api_v1_field_recording_path(first), headers: @headers
    import(transcript_text: TEXT, import_key: "pa:one")
    assert_response :conflict
    get api_v1_field_recordings_path(import_key: "pa:one"), headers: @headers
    assert_empty response.parsed_body["recordings"]
  end

  test "two files sharing a filename stay two recordings unless the importer gives them one key" do
    import(blob: pinned_blob(account: @account, user: @user), transcript_text: TEXT, import_key: "raw")
    import(blob: pinned_blob(account: @account, user: @user), transcript_text: TEXT, import_key: "edited")
    assert_equal 2, @account.field_recordings.where(import_key: %w[raw edited]).count
  end

  test "structured turns, and what is refused" do
    import(transcript_turns: [ { speaker: "Speaker A", start_ms: 0, text: "Hi" }, { speaker: "Ioan", text: "Salut" } ])
    assert_response :created
    assert_equal [ "Speaker 1", "Ioan" ], response.parsed_body.dig("recording", "speakers").map { |s| s["name"] }

    [
      { transcript_text: "x", transcript_turns: [ { text: "x" } ] },
      { transcript_turns: "not a list" },
      { transcript_turns: [ "not an object" ] },
      { transcript_text: "   " },
      { transcript_text: TEXT, language_code: "English" },
      { transcript_text: TEXT, recorded_at: "last tuesday" },
      { language_code: "en" }
    ].each do |params|
      assert_no_difference(-> { FieldRecording.count }, params.inspect) { import(**params) }
      assert_response :unprocessable_entity
    end
  end

  test "a plain upload can carry provenance too, and is transcribed as before" do
    import(title: "Call", recorded_at: "2026-03-25", source_path: "~/Recordings/call.m4a", import_key: "mac:call")
    assert_response :created
    recording = @account.field_recordings.find(response.parsed_body.dig("recording", "id"))
    assert_equal [ "probing", "vendor" ], [ recording.status, recording.transcript_source ]
    assert_equal Date.new(2026, 3, 25), recording.recorded_at.to_date
  end

  test "naming a speaker re-renders the supplied transcript; no voice sample can be cut from it" do
    import(transcript_text: TEXT)
    recording = @account.field_recordings.find(response.parsed_body.dig("recording", "id"))
    anna = recording.speakers.find_by(label: "Anna")
    anna.name_as!(@account.field_voices.create!(name: "Anna Tam"), by: @user)
    assert_includes recording.reload.transcript_text, "[00:21] Anna Tam: How am I feeling?"

    error = assert_raises(FieldVoiceprints::Sample::Refused) { FieldVoiceprints::Sample.segments_for(anna.reload) }
    assert_match(/no word timings/, error.message)
  end

  test "a resident reads the supplied transcript as plain text" do
    import(transcript_text: TEXT)
    id = response.parsed_body.dig("recording", "id")
    get api_v1_field_recording_path(id), headers: resident_headers(@user, agents(:research_assistant))
    assert_response :success
    assert_includes response.parsed_body.dig("recording", "transcript_text"), "Anna: How am I feeling?"
    %w[turns words audio].each { |key| assert_not_includes response.body, "\"#{key}" }
  end

end
