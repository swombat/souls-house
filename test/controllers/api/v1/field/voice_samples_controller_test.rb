require "test_helper"
require "support/api_human_key_helpers"
require "support/field_recording_helpers"
require "support/app_oauth_test_helper"

class Api::V1::Field::VoiceSamplesControllerTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers
  include FieldRecordingHelpers
  include ActiveJob::TestHelper
  include AppOauthTestHelper

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
    @voice = @account.field_voices.create!(name: "Upload API person")
  end

  def bytes(seed = 1)
    pcm = [ seed ].pack("s<") * 64_000
    "RIFF".b + [ pcm.bytesize + 36 ].pack("V") + "WAVEfmt " +
      [ 16, 1, 1, 16_000, 32_000, 2, 16 ].pack("VvvVVvv") + "data" + [ pcm.bytesize ].pack("V") + pcm
  end

  def with_voice(voice)
    previous, previous_headers = @voice, @headers
    @voice = voice
    @headers = human_headers(@user, voice.account)
    yield
  ensure
    @voice, @headers = previous, previous_headers
  end

  def upload(key: "api-upload-1", seed: 1, **metadata)
    file = Tempfile.new([ "synthetic", ".wav" ])
    file.binmode
    file.write(bytes(seed))
    file.rewind
    audio = Rack::Test::UploadedFile.new(file.path, "audio/wav")
    post api_v1_field_voice_samples_path(@voice), params: {
      audio:, idempotency_key: key, source_identifier: "synthetic-original",
      source_sha256: "a" * 64, source_session: "synthetic-session", **metadata
    }, headers: @headers
  ensure
    file&.close!
  end

  test "create and exact normalized resolve do not silently merge voices" do
    post api_v1_field_voices_path, params: { name: " New   Voice " }, headers: @headers, as: :json
    assert_response :created
    id = response.parsed_body.dig("voice", "id")
    get resolve_api_v1_field_voices_path, params: { name: "new voice" }, headers: @headers
    assert_response :success
    assert_equal id, response.parsed_body.dig("voice", "id")
    post api_v1_field_voices_path, params: { name: "NEW VOICE" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "machine uploads are pending retained candidates; retry download list inspect and remove are scoped" do
    assert_enqueued_with(job: FieldVoices::LearnUploadJob) { upload }
    assert_response :created
    row = response.parsed_body.fetch("sample")
    sample = @voice.samples.first!
    assert_equal "machine", sample.label_origin
    assert_not sample.eligible?
    assert_not row["confirmed"]
    assert_equal "synthetic-session", row["source_session"]
    assert_equal sample.source_group_key, row["source_group_key"]
    assert_not response.body.include?('"embedding"')
    assert_equal bytes, sample.audio.download

    assert_no_enqueued_jobs { assert_no_difference("FieldVoiceSample.count") { upload } }
    assert_response :success
    assert_equal "retry", response.parsed_body["deduplicated"]
    upload(seed: 2)
    assert_response :conflict

    get api_v1_field_voice_samples_path(@voice), headers: @headers
    assert_response :success
    assert_equal [ sample.to_param ], response.parsed_body["samples"].map { |item| item["id"] }
    get api_v1_field_voice_sample_path(@voice, sample), headers: @headers
    assert_response :success
    get audio_api_v1_field_voice_sample_path(@voice, sample), params: { digest: sample.source_digest }, headers: @headers
    assert_response :success
    assert_equal bytes, response.body.b
    assert_equal "private, no-store", response.headers["Cache-Control"]

    patch api_v1_field_voice_sample_path(@voice, sample), params: { included: true, digest: sample.source_digest }, headers: @headers, as: :json
    assert_response :forbidden
    assert_not sample.reload.manually_confirmed?
    patch api_v1_field_voice_sample_path(@voice, sample), params: { included: false, digest: sample.source_digest }, headers: @headers, as: :json
    assert_response :success
    assert sample.reload.excluded?

    delete api_v1_field_voice_sample_path(@voice, sample), params: { digest: sample.source_digest }, headers: @headers, as: :json
    assert_response :no_content
    assert sample.reload.removed_at
    assert sample.audio.attached?, "removal does not silently erase retained source"
    get api_v1_field_voice_sample_path(@voice, sample), headers: @headers
    assert_response :not_found
  end

  test "upload receipts distinguish identical content and overlapping cuts from new rows" do
    upload(start_ms: 0, end_ms: 4_000)
    assert_response :created
    original = response.parsed_body.fetch("sample")
    assert_nil response.parsed_body["deduplicated"]
    upload(key: "identical", start_ms: 0, end_ms: 4_000)
    assert_response :ok
    assert_equal "identical", response.parsed_body["deduplicated"]
    assert_equal original, response.parsed_body["sample"]
    upload(key: "overlap", seed: 2, start_ms: 2_000, end_ms: 6_000)
    assert_response :ok
    assert_equal "overlap", response.parsed_body["deduplicated"]
    assert_equal original, response.parsed_body["sample"]
    assert_not_equal Digest::SHA256.hexdigest(bytes(2)), response.parsed_body.dig("sample", "content_sha256")
    assert_equal 1, @voice.samples.count
  end

  test "browser confirms precisely the retained upload after embedding without a recording" do
    upload
    assert_response :created
    sample = @voice.samples.first!
    client = Object.new
    heard = nil
    client.define_singleton_method(:embed) do |wav|
      heard = wav
      FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: [ 1.0 ] + [ 0.0 ] * 191, profile: FieldVoiceprints::Profiles::ECAPA)
    end
    assert_equal :learned, FieldVoiceSamples::Uploads.learn!(sample, client:)
    assert_equal bytes, heard
    sample.reload
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    get account_field_voice_samples_path(@account, @voice)
    assert_response :success
    row = response.parsed_body["samples"].first
    assert_equal "review", row["state"]
    assert row["audio_url"]
    get row["audio_url"]
    assert_response :success
    assert_equal heard, response.body.b
    patch account_field_voice_sample_path(@account, @voice, row["id"]),
      params: { included: true, digest: sample.source_digest }, as: :json
    assert_response :success
    assert sample.reload.manually_confirmed?
    assert sample.eligible?
    assert_nil @voice.reload.voiceprint, "one confirmed sample cannot enroll"
    get account_field_voices_path(@account)
    assert_response :success
  end

  test "correction invalidates confirmation and stale digests cannot mutate or download" do
    upload
    assert_response :created
    sample = @voice.samples.first!
    old_digest = sample.source_digest
    other = @account.field_voices.create!(name: "Corrected upload")
    patch api_v1_field_voice_sample_path(@voice, sample),
      params: { voice_id: other.to_param, digest: old_digest }, headers: @headers, as: :json
    assert_response :success
    assert_equal other.id, sample.reload.field_voice_id
    assert_not_equal old_digest, sample.source_digest
    assert_not sample.manually_confirmed?
    get audio_api_v1_field_voice_sample_path(other, sample), params: { digest: old_digest }, headers: @headers
    assert_response :conflict
    get api_v1_field_voice_sample_path(@voice, sample), headers: @headers
    assert_response :not_found
  end

  test "optional recording links are account scoped for people and residents" do
    foreign = ready_recording(account: accounts(:team_account), user: @user)
    upload(recording_id: foreign.to_param)
    assert_response :not_found
    assert_empty @voice.samples
    @headers = resident_headers(@user, agents(:research_assistant))
    upload(recording_id: foreign.to_param)
    assert_response :not_found
    assert_empty @voice.samples
  end

  test "a resident uploads, lists, inspects, downloads and manages unconfirmed candidates as itself" do
    agent = agents(:research_assistant)
    @headers = resident_headers(@user, agent)
    assert_enqueued_with(job: FieldVoices::LearnUploadJob) { upload }
    assert_response :created
    sample = @voice.samples.first!
    assert_equal "machine", sample.label_origin
    assert_nil sample.uploaded_by_id, "the key's owner is not the uploader"
    assert_not sample.eligible?
    assert_not sample.ever_confirmed?
    audit = AuditLog.find_by!(action: "field_voice_sample_uploaded", auditable: sample)
    assert_nil audit.user_id
    assert_equal agent.id, audit.data["agent_id"]
    assert_equal @account.id, audit.account_id

    get api_v1_field_voice_samples_path(@voice), headers: @headers
    assert_response :success
    assert_equal [ sample.to_param ], response.parsed_body.fetch("samples").map { |row| row["id"] }
    get api_v1_field_sample_path(sample), headers: @headers
    assert_response :success
    get audio_api_v1_field_sample_path(sample), params: { digest: sample.source_digest }, headers: @headers
    assert_response :success
    assert_equal bytes, response.body.b

    patch api_v1_field_sample_path(sample), params: { included: false, digest: sample.source_digest }, headers: @headers, as: :json
    assert_response :success
    assert sample.reload.excluded?
    assert AuditLog.exists?(action: "field_voice_sample_excluded", auditable: sample, user_id: nil)

    target = @account.field_voices.create!(name: "Resident corrected")
    patch api_v1_field_sample_path(sample), params: { voice_id: target.to_param, digest: sample.source_digest }, headers: @headers, as: :json
    assert_response :success
    assert_equal target.id, sample.reload.field_voice_id
    assert_equal "machine", sample.label_origin
    assert_not sample.ever_confirmed?
    assert AuditLog.exists?(action: "field_voice_sample_reattributed", auditable: sample, user_id: nil)

    delete api_v1_field_sample_path(sample), params: { digest: sample.source_digest }, headers: @headers, as: :json
    assert_response :no_content
    assert sample.reload.removed_at
    assert AuditLog.exists?(action: "field_voice_sample_removed", auditable: sample, user_id: nil)
  end

  test "a resident never reads a linked recording's date through a sample; explicit upload provenance stays" do
    recording = ready_recording(account: @account, user: @user)
    recording.update_columns(recorded_at: Time.utc(2019, 5, 6, 7, 8, 9))
    resident = resident_headers(@user, agents(:research_assistant))
    human = @headers

    @headers = resident
    upload(key: "linked-undated", recording_id: recording.to_param)
    assert_response :created
    undated = @voice.samples.find_by!(idempotency_key: "linked-undated")
    assert_equal recording.to_param, response.parsed_body.dig("sample", "recording_id")
    assert_nil response.parsed_body.dig("sample", "recorded_at")
    get api_v1_field_sample_path(undated), headers: resident
    assert_nil response.parsed_body.dig("sample", "recorded_at")
    get api_v1_field_voice_samples_path(@voice), headers: resident
    assert_equal [ nil ], response.parsed_body.fetch("samples").map { |row| row["recorded_at"] }

    upload(key: "linked-dated", seed: 2, recording_id: recording.to_param, recorded_at: "2020-02-03")
    assert_response :created
    assert_equal "2020-02-03T00:00:00Z", response.parsed_body.dig("sample", "recorded_at")
    dated = @voice.samples.find_by!(idempotency_key: "linked-dated")
    get api_v1_field_sample_path(dated), headers: resident
    assert_equal "2020-02-03T00:00:00Z", response.parsed_body.dig("sample", "recorded_at")

    # A person's credential keeps the shared presentation, fallback included.
    get api_v1_field_sample_path(undated), headers: human
    assert_equal recording.recorded_at.iso8601, response.parsed_body.dig("sample", "recorded_at")
  end

  test "a resident cannot confirm, nor change a sample a person has confirmed" do
    upload
    assert_response :created
    sample = @voice.samples.first!
    sample.update!(embedding: JSON.generate([ 1.0 ] + [ 0.0 ] * 191), profile: FieldVoiceprints::Profiles::ECAPA, learning_status: "learned")
    resident = resident_headers(@user, agents(:research_assistant))
    patch api_v1_field_sample_path(sample), params: { included: true, digest: sample.source_digest }, headers: resident, as: :json
    assert_response :forbidden
    assert_not sample.reload.eligible?
    assert_not sample.ever_confirmed?

    @client = create_app_client
    tokens = sign_in_device
    patch api_v1_field_sample_path(sample), params: { included: true, digest: sample.source_digest },
      headers: bearer(tokens), as: :json
    assert_response :success
    assert sample.reload.manually_confirmed?
    digest = sample.source_digest
    other = @account.field_voices.create!(name: "Not this person")

    patch api_v1_field_sample_path(sample), params: { included: false, digest: }, headers: resident, as: :json
    assert_response :forbidden
    patch api_v1_field_sample_path(sample), params: { voice_id: other.to_param, digest: }, headers: resident, as: :json
    assert_response :forbidden
    delete api_v1_field_sample_path(sample), params: { digest: }, headers: resident, as: :json
    assert_response :forbidden
    sample.reload
    assert sample.eligible?
    assert sample.manually_confirmed?
    assert_equal @voice.id, sample.field_voice_id
    assert_nil sample.removed_at

    # Excluded but once confirmed is still a person's: re-inclusion would
    # reuse their testimony.
    patch api_v1_field_sample_path(sample), params: { included: false, digest: }, headers: @headers, as: :json
    assert_response :success
    patch api_v1_field_sample_path(sample), params: { included: true, digest: }, headers: resident, as: :json
    assert_response :forbidden
    assert_not sample.reload.eligible?
  end

  test "the unconfirmed guard is enforced under the sample lock, not only in the controller" do
    upload
    sample = @voice.samples.first!
    sample.update_columns(confirmed_by_id: @user.id, confirmed_at: Time.current, confirmed_digest: sample.source_digest)
    assert_raises(FieldVoiceSamples::Forbidden) { sample.remove!(digest: sample.source_digest, by: nil, unconfirmed_only: true) }
    assert_raises(FieldVoiceSamples::Forbidden) do
      sample.reattribute!(voice: @account.field_voices.create!(name: "Elsewhere"), digest: sample.source_digest, by: nil, unconfirmed_only: true)
    end
    assert_raises(FieldVoiceSamples::Forbidden) { sample.review!(digest: sample.source_digest, by: nil, included: false, unconfirmed_only: true) }
    assert_nil sample.reload.removed_at
    assert_equal @voice.id, sample.field_voice_id
  end

  test "a resident reaches only its home account and never recording-backed samples" do
    resident = resident_headers(@user, agents(:research_assistant))
    team = accounts(:team_account)
    team_voice = team.field_voices.create!(name: "Team voice")
    team_sample = with_voice(team_voice) { upload(key: "team-upload") ; team_voice.samples.first! }
    assert team_sample

    get api_v1_field_voice_samples_path(team_voice), headers: resident
    assert_response :not_found
    get api_v1_field_sample_path(team_sample), headers: resident
    assert_response :not_found
    get audio_api_v1_field_sample_path(team_sample), params: { digest: team_sample.source_digest }, headers: resident
    assert_response :not_found
    delete api_v1_field_sample_path(team_sample), params: { digest: team_sample.source_digest }, headers: resident, as: :json
    assert_response :not_found
    assert_nil team_sample.reload.removed_at
    get api_v1_field_voice_samples_path(@voice), params: { account_id: team.to_param }, headers: resident
    assert_response :not_found

    recording = long_ready_recording(account: @account, user: @user)
    speaker = recording.speakers.first
    speaker.name_as!(@voice, by: @user)
    segments = [ [ 0, 5_000 ] ]
    backed = FieldVoiceSample.new(account: @account, field_voice: @voice, field_recording_speaker: speaker,
      field_recording_id: recording.id, speech_ms: 5_000, profile: "ecapa-test", eligible: false,
      label_origin: "human", source_segments: segments, source_digest: FieldVoiceSample.source_digest_for(speaker.reload, segments))
    backed.vector = voice_vector(1)
    backed.save!
    get api_v1_field_voice_samples_path(@voice), headers: resident
    assert_response :success
    assert_empty response.parsed_body.fetch("samples")
    get api_v1_field_sample_path(backed), headers: resident
    assert_response :not_found
    get audio_api_v1_field_sample_path(backed), params: { digest: backed.source_digest }, headers: resident
    assert_response :not_found
    patch api_v1_field_sample_path(backed), params: { included: false, digest: backed.source_digest }, headers: resident, as: :json
    assert_response :not_found
    delete api_v1_field_sample_path(backed), params: { digest: backed.source_digest }, headers: resident, as: :json
    assert_response :not_found
    assert FieldVoiceSample.exists?(id: backed.id, removed_at: nil)
  end

  test "an uploaded sample exposes its account-scoped transcript link" do
    recording = ready_recording(account: @account, user: @user)
    upload(transcript_id: recording.to_param)
    assert_response :created
    assert_equal recording.to_param, response.parsed_body.dig("sample", "recording_id")
    assert_equal "upload", response.parsed_body.dig("sample", "kind")
  end

  test "top-level attribution uses the sample's original voice rather than the body target" do
    upload
    assert_response :created
    sample = @voice.samples.first!
    target = @account.field_voices.create!(name: "Top-level corrected person")
    patch api_v1_field_sample_path(sample), params: { voice_id: target.to_param, digest: sample.source_digest },
      headers: @headers, as: :json
    assert_response :success
    assert_equal target.id, sample.reload.field_voice_id
    assert_not sample.manually_confirmed?
  end

  test "only the authenticated human app creates testimony; a key can reuse but not rewrite it" do
    upload
    assert_response :created
    sample = @voice.samples.first!
    sample.update!(embedding: JSON.generate([ 1.0 ] + [ 0.0 ] * 191), profile: FieldVoiceprints::Profiles::ECAPA, learning_status: "learned")
    @client = create_app_client
    tokens = sign_in_device
    patch api_v1_field_sample_path(sample), params: { included: true, digest: sample.source_digest },
      headers: bearer(tokens), as: :json
    assert_response :success
    assert sample.reload.manually_confirmed?
    confirmed_at = sample.confirmed_at
    assert_equal @user.id, sample.confirmed_by_id
    patch api_v1_field_sample_path(sample), params: { included: false, digest: sample.source_digest },
      headers: @headers, as: :json
    assert_response :success
    patch api_v1_field_sample_path(sample), params: { included: true, digest: sample.source_digest },
      headers: @headers, as: :json
    assert_response :success
    assert_equal confirmed_at, sample.reload.confirmed_at
    assert sample.manually_confirmed?
  end

  test "sample member paths never broaden an account key's reach" do
    upload
    assert_response :created
    sample = @voice.samples.first!
    other_headers = human_headers(@user, accounts(:team_account))
    get api_v1_field_sample_path(sample), headers: other_headers
    assert_response :not_found
    get audio_api_v1_field_sample_path(sample), params: { digest: sample.source_digest }, headers: other_headers
    assert_response :not_found
    patch api_v1_field_sample_path(sample), params: { included: false, digest: sample.source_digest },
      headers: other_headers, as: :json
    assert_response :not_found
    assert_not sample.reload.excluded?
  end

  test "a key corrects recording attribution without losing the reviewable cut or inventing listening" do
    recording = long_ready_recording(account: @account, user: @user)
    speaker = recording.speakers.first
    speaker.name_as!(@voice, by: @user)
    segments = [ [ 0, 5_000 ] ]
    original = FieldVoiceSample.new(account: @account, field_voice: @voice, field_recording_speaker: speaker,
      field_recording_id: recording.id, speech_ms: 5_000, profile: "ecapa-test", eligible: false,
      label_origin: "human", source_segments: segments, source_digest: FieldVoiceSample.source_digest_for(speaker.reload, segments))
    original.vector = voice_vector(1)
    original.save!
    target = @account.field_voices.create!(name: "Actually this person")
    patch api_v1_field_sample_path(original), params: { voice_id: target.to_param, digest: original.source_digest },
      headers: @headers, as: :json
    assert_response :success
    replacement = target.samples.first!
    assert_equal target.id, speaker.reload.field_voice_id
    assert_equal "machine", speaker.naming_source
    assert_not FieldVoiceSample.exists?(id: original.id)
    assert_equal original.vector, replacement.vector
    assert_equal original.source_segments, replacement.source_segments
    assert replacement.source_current?
    assert_not replacement.eligible?
    assert_not replacement.manually_confirmed?
  end

end
