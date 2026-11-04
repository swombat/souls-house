require "test_helper"
require "support/field_recording_helpers"

class Api::V1::Field::RecordingsControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @resident = agents(:research_assistant)
    @account = @resident.account
    key = ApiKey.generate_for(@user, name: "Field tests", agent: @resident)
    @headers = { "Authorization" => "Bearer #{key.raw_token}" }
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
  end

  test "a resident downloads only its home recording audio through an expiring attachment URL" do
    [ {}, { account_id: @account.to_param } ].each do |params|
      get audio_api_v1_field_recording_path(@recording), params:, headers: @headers
      assert_response :redirect
      location = URI.parse(response.location)
      token = location.path.split("/").last(2).first
      download = ActiveStorage.verifier.verified(token, purpose: :blob_key).with_indifferent_access
      assert_equal @recording.audio.blob.key, download.fetch(:key)
      assert_includes download.fetch(:disposition), "attachment"

      travel 6.minutes do
        assert_nil ActiveStorage.verifier.verified(token, purpose: :blob_key)
      end
    end
  end

  test "audio is not available without authentication" do
    get audio_api_v1_field_recording_path(@recording)
    assert_response :unauthorized
  end

  test "resident audio refuses cross-account and guest recordings and foreign account selectors" do
    other_account = accounts(:team_account)
    theirs = ready_recording(account: other_account, user: @user)
    get audio_api_v1_field_recording_path(theirs), headers: @headers
    assert_response :not_found

    other_account.guest_memberships.create!(agent: @resident, added_by: @user)
    get audio_api_v1_field_recording_path(theirs), headers: @headers
    assert_response :not_found
    [ @recording, theirs ].each do |recording|
      get audio_api_v1_field_recording_path(recording), params: { account_id: other_account.to_param }, headers: @headers
      assert_response :not_found
      assert_nil response.headers["Location"]
    end
  end

  test "resident audio refuses discarded recordings, missing recordings and missing audio" do
    @recording.audio.purge
    get audio_api_v1_field_recording_path(@recording), headers: @headers
    assert_response :not_found

    discarded = ready_recording(account: @account, user: @user)
    discarded.discard_and_settle!
    get audio_api_v1_field_recording_path(discarded), headers: @headers
    assert_response :not_found
    get audio_api_v1_field_recording_path("missing"), headers: @headers
    assert_response :not_found
  end

  test "audio access does not admit resident recording uploads or lifecycle writes" do
    assert_no_difference -> { FieldRecording.count } do
      post api_v1_field_recordings_path, params: { upload_id: @recording.audio.blob.signed_id }, headers: @headers, as: :json
      assert_response :forbidden
      post retry_api_v1_field_recording_path(@recording), headers: @headers
      assert_response :forbidden
    end
    patch api_v1_field_recording_path(@recording), params: { title: "Not allowed" }, headers: @headers, as: :json
    assert_response :forbidden
    delete api_v1_field_recording_path(@recording), headers: @headers
    assert_response :forbidden
    assert_equal "Board call", @recording.reload.title
    assert @recording.kept?
  end

  test "a resident reads transcripts with the names humans set, and nothing else" do
    @recording.speakers.first.name_as!(@account.field_voices.create!(name: "Priya"), by: @user)

    get api_v1_field_recordings_path, headers: @headers
    assert_response :success
    assert_equal [ "Board call" ], response.parsed_body["recordings"].map { |r| r["title"] }

    get api_v1_field_recording_path(@recording), headers: @headers
    body = response.parsed_body["recording"]
    assert_equal "[00:00] Priya: hello\n[00:02] Speaker 2: there", body["transcript_text"]
    assert_equal [ "Priya", "Speaker 2" ], body["speakers"].map { |s| s["name"] }
    json = response.body
    @recording.speakers.last.update!(suggested_name: "Tomás", suggestion_quote: "there", suggestion_source: "utility")
    get api_v1_field_recording_path(@recording), headers: @headers
    json = response.body
    assert_not_includes json, "Tomás"
    %w[audio voice_id field_voice print words naming_source suggest].each { |key| assert_not_includes json, "\"#{key}" }
  end

  test "a resident reads the transcript as numbered lines and corrects one" do
    @recording.speakers.first.name_as!(@account.field_voices.create!(name: "Priya"), by: @user)

    get lines_api_v1_field_recording_path(@recording), headers: @headers
    assert_response :success
    body = response.parsed_body
    assert_equal [ { "line" => 1, "speaker" => "Priya", "text" => "hello" },
                   { "line" => 2, "speaker" => "Speaker 2", "text" => "there" } ], body["lines"].map { |line| line.except("speaker_id") }
    assert_equal @recording.speakers.in_order.map(&:to_param), body["lines"].map { |line| line["speaker_id"] }
    assert_equal @recording.transcript_revision, body["revision"]
    %w[locator first last "s" "e"].each { |key| assert_not_includes response.body, key }

    patch line_api_v1_field_recording_path(@recording, line: 2), headers: @headers,
      params: { text: "Dan", was: "there", revision: body["revision"] }, as: :json
    assert_response :success
    assert_equal({ "line" => 2, "speaker" => "Speaker 2", "text" => "Dan" }, response.parsed_body["line"].except("speaker_id"))
    @recording.reload
    assert_equal response.parsed_body["revision"], @recording.transcript_revision
    assert_includes @recording.transcript_text, "Speaker 2: Dan"
    assert_equal [ 2000, 2600 ], @recording.transcript_words.last.values_at("s", "e"), "the replaced word keeps its time"
  end

  test "a resident gives a line to another speaker, or to someone new" do
    get lines_api_v1_field_recording_path(@recording), headers: @headers
    body = response.parsed_body
    first, second = body["lines"].map { |line| line["speaker_id"] }

    patch line_api_v1_field_recording_path(@recording, line: 2), headers: @headers,
      params: { speaker: "new", was: "there", revision: body["revision"] }, as: :json
    assert_response :success
    @recording.reload
    assert_equal [ "speaker_0", "speaker_2" ], @recording.speakers.in_order.map(&:label), "the emptied speaker goes"
    assert_includes @recording.transcript_text, "Speaker 3: there"
    assert_equal first, response.parsed_body["lines"].first["speaker_id"]
    assert_not_equal second, response.parsed_body["line"]["speaker_id"]

    patch line_api_v1_field_recording_path(@recording, line: 2), headers: @headers,
      params: { speaker: first, was: "there", revision: response.parsed_body["revision"] }, as: :json
    assert_response :success
    assert_equal 1, response.parsed_body["lines"].size, "one speaker's words are one line"
    assert_equal response.parsed_body["lines"].first, response.parsed_body["line"], "the line the moved words are in now"
    assert_equal [ "speaker_0" ], @recording.reload.speakers.map(&:label)

    patch line_api_v1_field_recording_path(@recording, line: 1), headers: @headers,
      params: { speaker: "nobody", was: "hello there", revision: @recording.transcript_revision }, as: :json
    assert_response :unprocessable_entity
    patch line_api_v1_field_recording_path(@recording, line: 1), headers: @headers,
      params: { speaker: "new", was: "hello there", revision: "0000000000000000" }, as: :json
    assert_response :conflict
    assert_equal [ "speaker_0" ], @recording.reload.speakers.map(&:label)
  end

  test "a correction against an old revision, a moved line or a missing line is refused and changes nothing" do
    get lines_api_v1_field_recording_path(@recording), headers: @headers
    revision = response.parsed_body["revision"]
    before = @recording.transcript_words

    [ [ 2, "there", "0000000000000000" ], [ 2, "hello", revision ], [ 9, "there", revision ], [ "x", "there", revision ] ].each do |line, was, rev|
      patch line_api_v1_field_recording_path(@recording, line:), headers: @headers,
        params: { text: "Dan", was:, revision: rev }, as: :json
      assert_response :conflict
      assert_equal revision, response.parsed_body["revision"]
    end
    assert_equal before, @recording.reload.transcript_words

    patch line_api_v1_field_recording_path(@recording, line: 2), headers: @headers,
      params: { text: "  ", was: "there", revision: }, as: :json
    assert_response :unprocessable_entity
    patch line_api_v1_field_recording_path(@recording, line: 2), headers: @headers,
      params: { text: "Dan", was: "there" }, as: :json
    assert_response :unprocessable_entity
    assert_equal before, @recording.reload.transcript_words
  end

  test "correction fields that aren't strings are refused and nothing is written" do
    get lines_api_v1_field_recording_path(@recording), headers: @headers
    revision = response.parsed_body["revision"]
    before = @recording.transcript_words

    [ { text: { bad: "shape" }, was: "there", revision: },
      { text: [ "Dan" ], was: "there", revision: },
      { text: 7, was: "there", revision: },
      { text: "Dan", was: { t: "there" }, revision: },
      { text: "Dan", was: "there", revision: [ revision ] } ].each do |params|
      patch line_api_v1_field_recording_path(@recording, line: 2), headers: @headers, params:, as: :json
      assert_response :unprocessable_entity, params.inspect
      assert_match "as a string", response.parsed_body["error"]
    end
    @recording.reload
    assert_equal before, @recording.transcript_words
    assert_equal revision, @recording.transcript_revision
  end

  test "lines need a transcript, and another account's recording is out of reach" do
    queued = queued_recording(account: @account, user: @user)
    get lines_api_v1_field_recording_path(queued), headers: @headers
    assert_response :conflict
    patch line_api_v1_field_recording_path(queued, line: 1), headers: @headers,
      params: { text: "x", was: "y", revision: "z" }, as: :json
    assert_response :conflict

    other = ready_recording(account: accounts(:team_account), user: @user)
    get lines_api_v1_field_recording_path(other), headers: @headers
    assert_response :not_found
  end

  test "a resident reads a recording's notes" do
    @recording.update!(notes: "- Ask Priya about the board pack")
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_equal "- Ask Priya about the board pack", response.parsed_body.dig("recording", "notes")
  end

  test "summary freshness reaches both resident list and detail without exposing provenance" do
    @recording.update_columns(summary_short: "Board call", summary_long: "An earlier board call.", summarized_at: Time.current)
    get api_v1_field_recordings_path, headers: @headers
    listed = response.parsed_body["recordings"].find { |r| r["id"] == @recording.to_param }
    assert_equal "unknown", listed["summary_freshness"]
    assert_equal "An earlier board call.", listed["summary_long"]

    get api_v1_field_recording_path(@recording), headers: @headers
    body = response.parsed_body["recording"]
    assert_equal "unknown", body["summary_freshness"]
    assert_equal false, body["summary_pending"]
    assert_not body.key?("summary_input_digest")
    assert_not body.key?("summary_claim_token")

    @recording.update_columns(summary_input_digest: FieldSummaries.current_input_digest(@recording))
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_equal "current", response.parsed_body.dig("recording", "summary_freshness")

    @recording.update!(transcript_text: "#{@recording.transcript_text}\nA correction.")
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_equal "stale", response.parsed_body.dig("recording", "summary_freshness")
  end

  test "two diarized speakers linked to one voice are one speaker to a resident" do
    ioan = @account.field_voices.create!(name: "Ioan")
    @recording.speakers.each { |speaker| speaker.name_as!(ioan, by: @user) }

    get api_v1_field_recording_path(@recording), headers: @headers
    body = response.parsed_body["recording"]
    assert_equal [ { "label" => "Speaker 1", "name" => "Ioan", "talk_ms" => @recording.speakers.sum(:talk_ms),
                     "diarized_as" => [ "Speaker 1", "Speaker 2" ] } ], body["speakers"]
    assert_equal 1, body["transcript_text"].lines.size, "their consecutive turns join"
  end

  test "unfinished recordings have no transcript yet, and discarded ones are gone" do
    queued = queued_recording(account: @account, user: @user)
    get api_v1_field_recording_path(queued), headers: @headers
    assert_nil response.parsed_body.dig("recording", "transcript_text")

    @recording.discard_and_settle!
    get api_v1_field_recording_path(@recording), headers: @headers
    assert_response :not_found
  end

  test "another account's recordings can't be reached" do
    theirs = ready_recording(account: accounts(:another_team), user: @user)
    get api_v1_field_recording_path(theirs), headers: @headers
    assert_response :not_found
  end

end
