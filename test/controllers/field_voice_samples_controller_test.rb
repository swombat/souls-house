require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceSamplesControllerTest < ActionDispatch::IntegrationTest

  include ActiveJob::TestHelper
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
    assert_equal "review", row["state"]
    assert_not response.body.include?("embedding")
    assert_not response.body.include?("ecapa-test")
    assert_equal 0, body["other_namings"]
    assert_equal 0, body["preparable"]
  end

  test "the review list holds only samples; other namings are a count, listed with reasons on request" do
    others = 3.times.map do |index|
      recording = long_ready_recording(account: @account, user: @user, title: "Synthetic other #{index}")
      recording.speakers.find_by!(label: "speaker_1").tap { |speaker| speaker.name_as!(@voice, by: @user) }
    end
    get account_field_voice_samples_path(@account, @voice)
    body = response.parsed_body
    assert_equal [ @speaker.to_param ], body["samples"].map { |row| row["id"] }
    assert_equal 3, body["other_namings"]

    get account_field_voice_samples_path(@account, @voice, scope: "other")
    body = response.parsed_body
    assert_equal others.map(&:to_param).sort, body["namings"].map { |row| row["id"] }.sort
    assert_equal 3, body["total"]
    assert body["namings"].all? { |row| row["reason"].present? }
    assert_not response.body.include?("embedding")
  end

  test "every sample stays reachable: review order is decided over all of them before paging" do
    stub_const = FieldVoiceSamplesController::SAMPLES_PAGE
    FieldVoiceSamplesController.send(:remove_const, :SAMPLES_PAGE)
    FieldVoiceSamplesController.const_set(:SAMPLES_PAGE, 2)
    extra = 3.times.map do |index|
      recording = long_ready_recording(account: @account, user: @user, title: "Synthetic page #{index}")
      speaker = recording.speakers.find_by!(label: "speaker_0")
      speaker.name_as!(@voice, by: @user)
      sample = @voice.samples.new(account: @account, field_recording_speaker: speaker, field_recording_id: recording.id,
        speech_ms: 12_000, profile: "ecapa-test", label_origin: "human", eligible: true, source_segments: [ [ 0, 12_000 ] ])
      sample.source_digest = FieldVoiceSample.source_digest_for(speaker.reload, sample.source_segments)
      sample.vector = voice_vector(index + 2)
      sample.save!
      speaker
    end
    # The oldest sample is the only one needing review: it must lead page 1,
    # not fall off the end of a newest-first cap.
    extra.each do |speaker|
      sample = speaker.voice_samples.first
      speaker.update!(sample_confirmed_digest: sample.source_digest, sample_confirmed_by: @user, sample_confirmed_at: Time.current)
    end

    get account_field_voice_samples_path(@account, @voice)
    body = response.parsed_body
    assert_equal [ 1, 2, 4 ], [ body["page"], body["pages"], body["total"] ]
    assert_equal({ "review" => 1, "confirmed" => 3 }, body["state_counts"])
    assert_equal [ @speaker.to_param, "review" ], [ body["samples"].first["id"], body["samples"].first["state"] ]

    seen = (1..2).flat_map do |page|
      get account_field_voice_samples_path(@account, @voice, page:)
      response.parsed_body["samples"].map { |row| row["id"] }
    end
    assert_equal ([ @speaker ] + extra).map(&:to_param).sort, seen.sort
    get account_field_voice_samples_path(@account, @voice, page: 99)
    assert_equal 2, response.parsed_body["page"], "an out-of-range page clamps to the last"
  ensure
    FieldVoiceSamplesController.send(:remove_const, :SAMPLES_PAGE)
    FieldVoiceSamplesController.const_set(:SAMPLES_PAGE, stub_const)
  end

  test "rows needing review come before confirmed and removed ones" do
    recording = long_ready_recording(account: @account, user: @user, title: "Synthetic second")
    second = recording.speakers.find_by!(label: "speaker_0")
    second.name_as!(@voice, by: @user)
    sample = @voice.samples.new(account: @account, field_recording_speaker: second, field_recording_id: recording.id,
      speech_ms: 17_000, profile: "ecapa-test", label_origin: "human", eligible: true, source_segments: [ [ 0, 12_000 ] ])
    sample.source_digest = FieldVoiceSample.source_digest_for(second.reload, sample.source_segments)
    sample.vector = voice_vector(2)
    sample.save!
    patch account_field_voice_sample_path(@account, @voice, @speaker),
      params: { included: true, digest: @sample.source_digest }, as: :json
    assert_response :success

    get account_field_voice_samples_path(@account, @voice)
    assert_equal [ [ second.to_param, "review" ], [ @speaker.to_param, "confirmed" ] ],
      response.parsed_body["samples"].map { |row| [ row["id"], row["state"] ] }
  end

  test "prepare rebuilds only samples that can't be heard yet, for this voice or the whole account" do
    with_recognition(@account) do
      post prepare_account_field_voice_samples_path(@account, @voice), as: :json
      assert_response :success
      assert_equal 0, response.parsed_body["queued"], "a current sample is left alone"

      @sample.update!(source_segments: nil, source_digest: nil)
      get account_field_voice_samples_path(@account, @voice)
      assert_equal [ "not_ready", 1 ], [ response.parsed_body["samples"].first["state"], response.parsed_body["preparable"] ]

      assert_enqueued_with(job: FieldVoices::LearnSampleJob) do
        post prepare_account_field_voice_samples_path(@account, @voice), as: :json
      end
      assert_equal 1, response.parsed_body["queued"]
      assert @sample.reload.eligible?, "preparing keeps the sample in the fingerprint"
      get account_field_voice_samples_path(@account, @voice)
      assert_equal "preparing", response.parsed_body["samples"].first["state"]

      post prepare_account_field_voice_samples_path(@account, @voice), as: :json
      assert_equal 0, response.parsed_body["queued"], "a pending rebuild is not queued twice"

      @speaker.update_columns(sample_learning_status: nil)
      post prepare_samples_account_field_voices_path(@account), as: :json
      assert_response :success
      assert_equal 1, response.parsed_body["queued"]
    end
  end

  test "prepare is account scoped and refuses when learning is off" do
    other = accounts(:another_team).field_voices.create!(name: "Another Person")
    post prepare_account_field_voice_samples_path(@account, other), as: :json
    assert_response :not_found
    @sample.update!(source_segments: nil, source_digest: nil)
    @account.update!(recognise_voices: false)
    post prepare_account_field_voice_samples_path(@account, @voice), as: :json
    assert_equal 0, response.parsed_body["queued"]
    assert_no_enqueued_jobs(only: FieldVoices::LearnSampleJob) do
      post prepare_samples_account_field_voices_path(@account), as: :json
    end
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
    FieldVoiceSamples::Audio.clear
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

  test "warm cuts this voice's samples ahead, once, and play then uses that cut" do
    FieldVoiceSamples::Audio.clear
    FieldVoiceSamples::Audio.executor = Concurrent::ImmediateExecutor.new
    bytes = "RIFF" + ("warmed audio" * 50)
    passes = []
    cut_many = ->(recording, lists, &block) {
      passes << [ recording.id, lists ]
      Tempfile.create([ "warm", ".wav" ]) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        block.call(lists.map { file.path })
      end
    }
    other_account = accounts(:team_account)
    stranger = long_ready_recording(account: other_account, user: @user, title: "Not this account").speakers.first
    Rails.stub(:cache, -> { flunk "Private sample audio must never use the persistent Rails cache" }) do
      FieldVoiceprints::Sample.stub(:cut_many, cut_many) do
        FieldVoiceprints::Sample.stub(:cut, ->(*) { flunk "a warmed sample is not cut again" }) do
          ids = [ @speaker.to_param, stranger.to_param, "upload-#{@speaker.to_param}" ]
          post warm_account_field_voice_samples_path(@account, @voice), params: { ids: }, as: :json
          assert_response :success
          assert_equal 1, response.parsed_body["warming"]
          assert_equal [ [ @recording.id, [ @sample.source_segments ] ] ], passes

          post warm_account_field_voice_samples_path(@account, @voice), params: { ids: }, as: :json
          assert_equal 0, response.parsed_body["warming"], "a cut already made is not queued again"
          assert_equal 1, passes.size

          get audio_account_field_voice_sample_path(@account, @voice, @speaker, digest: @sample.source_digest)
          assert_response :success
          assert_equal bytes, response.body
        end
      end
    end
  ensure
    FieldVoiceSamples::Audio.executor = nil
    FieldVoiceSamples::Audio.clear
  end

  test "a play that arrives while its sample is being cut waits for that cut" do
    FieldVoiceSamples::Audio.clear
    started = Queue.new
    release = Queue.new
    FieldVoiceSamples::Audio.executor = nil # the real one-worker pool
    cut_many = ->(_recording, lists, &block) {
      started << true
      release.pop
      Tempfile.create([ "slow", ".wav" ]) do |file|
        file.binmode
        file.write("RIFFslow")
        file.flush
        block.call(lists.map { file.path })
      end
    }
    FieldVoiceprints::Sample.stub(:cut_many, cut_many) do
      FieldVoiceprints::Sample.stub(:cut, ->(*) { flunk "the cut under way is not started twice" }) do
        assert_equal 1, FieldVoiceSamples::Audio.warm(@account, [ [ @speaker, @sample ] ])
        started.pop
        waiter = Thread.new { FieldVoiceSamples::Audio.bytes(@account, @speaker, @sample) }
        sleep 0.05
        assert waiter.alive?, "the play waits"
        release << true
        assert_equal "RIFFslow", waiter.value
      end
    end
  ensure
    FieldVoiceSamples::Audio.executor&.shutdown
    FieldVoiceSamples::Audio.executor = nil
    FieldVoiceSamples::Audio.clear
  end

  test "with twenty included, a candidate is shown as not needed and the list says so" do
    @sample.update!(eligible: false)
    FieldVoiceprints::Limits.stub(:full?, true) do
      get account_field_voice_samples_path(@account, @voice), as: :json
    end
    assert_response :success
    assert response.parsed_body["full"]
    assert_equal "spare", response.parsed_body["samples"].first["state"]

    get account_field_voice_samples_path(@account, @voice), as: :json
    assert_not response.parsed_body["full"]
    assert_equal "review", response.parsed_body["samples"].first["state"]
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
