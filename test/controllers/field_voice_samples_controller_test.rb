require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceSamplesControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    @recording = long_ready_recording(account: @account, user: @user, title: "Synthetic sample recording")
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "Sample Person")
    @speaker.name_as!(@voice, by: @user)
    @sample = @voice.samples.new(account: @account, field_recording_speaker: @speaker,
      field_recording_id: @recording.id, speech_ms: 17_000, profile: "ecapa-test", label_origin: "human", eligible: true,
      source_segments: [ [ 0, 12_000 ], [ 17_000, 22_000 ] ])
    @sample.source_digest = FieldVoiceSample.source_digest_for(@speaker.reload, @sample.source_segments)
    @sample.vector = voice_vector(1)
    @sample.save!
  end

  test "samples are explicit safe projections with exact spans and independent states" do
    get account_field_voice_samples_path(@account, @voice)
    assert_response :success
    body = response.parsed_body
    row = body["samples"].first
    assert_equal @sample.source_segments, row["segments"]
    assert row["included"]
    assert_not row["confirmed"]
    assert row["audio_url"].present?
    assert_not response.body.include?("embedding")
    assert_not response.body.include?("ecapa-test")
    assert_equal 1, body["pages"]
  end

  test "approve excludes and includes persist without naming another cluster" do
    patch account_field_voice_sample_path(@account, @voice, @speaker),
      params: { included: true, digest: @sample.source_digest }, as: :json
    assert_response :success
    assert @sample.reload.manually_confirmed?
    assert_equal @user, @speaker.reload.sample_confirmed_by
    assert_equal "human", @speaker.naming_source

    patch account_field_voice_sample_path(@account, @voice, @speaker),
      params: { included: false, digest: @sample.source_digest }, as: :json
    assert_response :success
    assert_not @sample.reload.eligible?
    assert @sample.manually_confirmed?, "exclusion preserves confirmation"
    assert_nil @voice.reload.voiceprint
    assert_equal @voice.id, @speaker.reload.field_voice_id
  end

  test "stale digest cannot confirm and legacy spans are not invented" do
    patch account_field_voice_sample_path(@account, @voice, @speaker),
      params: { included: true, digest: "different" }, as: :json
    assert_response :conflict
    @sample.update!(source_segments: nil, source_digest: nil)
    get account_field_voice_samples_path(@account, @voice)
    row = response.parsed_body["samples"].first
    assert_nil row["segments"]
    assert_nil row["audio_url"]
    assert row["included"]
    assert_not row["confirmed"]
    assert_match(/Spans were not recorded/, row["unavailable"])
    patch account_field_voice_sample_path(@account, @voice, @speaker),
      params: { included: true, digest: nil }, as: :json
    assert_response :conflict
    patch account_field_voice_sample_path(@account, @voice, @speaker),
      params: { included: false, digest: nil }, as: :json
    assert_response :success
  end

  test "account and voice ownership protect every operation and media" do
    other = accounts(:another_team).field_voices.create!(name: "Another Person")
    [
      account_field_voice_samples_path(@account, other),
      account_field_voice_samples_path(accounts(:another_team), @voice),
      audio_account_field_voice_sample_path(@account, other, @speaker, digest: @sample.source_digest)
    ].each do |url|
      get url
      assert_response :not_found
    end
    patch account_field_voice_sample_path(@account, other, @speaker),
      params: { included: false, digest: @sample.source_digest }, as: :json
    assert_response :not_found
    post relearn_account_field_voice_sample_path(@account, other, @speaker)
    assert_response :not_found
  end

  test "authenticated audio serves inline wav and single byte ranges only" do
    bytes = "RIFF" + ("synthetic audio" * 100)
    cuts = 0
    cut = ->(_recording, segments, &block) {
      cuts += 1
      assert_equal @sample.source_segments, segments
      Tempfile.create([ "synthetic-review", ".wav" ]) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        block.call(file.path)
      end
    }
    url = audio_account_field_voice_sample_path(@account, @voice, @speaker, digest: @sample.source_digest)
    FieldVoiceSamplesController::AUDIO_CACHE.clear
    Rails.stub(:cache, -> { flunk "Private sample audio must never use the persistent Rails cache" }) do
      FieldVoiceprints::Sample.stub(:cut, cut) do
        get url
        assert_response :success
        assert_equal bytes, response.body
        assert_match(/inline/, response.headers["Content-Disposition"])
        assert_equal "audio/wav", response.media_type
        assert_match(/private.*no-store/, response.headers["Cache-Control"])
        assert_equal "bytes", response.headers["Accept-Ranges"]
        get url, headers: { "Range" => "bytes=0-3" }
        assert_response :partial_content
        assert_equal "RIFF", response.body
        assert_equal "bytes 0-3/#{bytes.bytesize}", response.headers["Content-Range"]
        get url, headers: { "Range" => "bytes=9999999-" }
        assert_response :range_not_satisfiable
        assert_equal 1, cuts, "Safari's probes and chunks reuse the same private cut"
        travel 11.minutes do
          get url, headers: { "Range" => "bytes=0-3" }
          assert_response :partial_content
          assert_equal 2, cuts, "expired process-local audio is cut again"
        end
        @speaker.increment!(:decision_generation)
        get url, headers: { "Range" => "bytes=0-3" }
        assert_response :conflict, "a cached cut does not bypass source checks"
        assert_equal 2, cuts
      end
    end
    get audio_account_field_voice_sample_path(@account, @voice, @speaker, digest: "stale")
    assert_response :conflict
    delete logout_path
    get url
    assert_response :redirect
  end

  test "missing audio is presented honestly and stale evidence cannot be streamed" do
    @speaker.increment!(:decision_generation)
    get audio_account_field_voice_sample_path(@account, @voice, @speaker, digest: @sample.source_digest)
    assert_response :conflict
    get account_field_voice_samples_path(@account, @voice)
    assert_match(/evidence changed/, response.parsed_body["samples"].first["unavailable"])
    @recording.audio.detach
    get account_field_voice_samples_path(@account, @voice)
    assert_equal "Source audio is missing", response.parsed_body["samples"].first["unavailable"]
  end

end
