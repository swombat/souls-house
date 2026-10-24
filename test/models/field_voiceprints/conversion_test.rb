require "test_helper"
require_relative "../../support/field_recording_helpers"

class FieldVoiceprints::ConversionTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  OLD = FieldVoiceprints::Profiles::ECAPA
  NEW = FieldVoiceprints::Profiles::WESPEAKER

  setup do
    @account = accounts(:team_account)
    @user = users(:user_1)
    @voice = @account.field_voices.create!(name: "Synthetic conversion fixture")
    store_print!(@voice)
    @samples = @voice.samples.order(:id).to_a
    Setting.instance.update!(voice_embedding_profile: NEW)
  end

  def client(&during)
    calls = []
    object = Object.new
    object.define_singleton_method(:embed) do |wav|
      calls << wav.bytesize
      during&.call
      FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: [ 1.0 ] + [ 0.0 ] * 255, profile: NEW)
    end
    object.define_singleton_method(:calls) { calls }
    object
  end

  def convert(sample, using = client)
    FieldVoiceprints::Conversion.convert!(sample.reload, target: NEW, client: using)
  end

  test "accounts created after cutover start in the configured empty space" do
    account = Account.create!(name: "Synthetic post-cutover account", account_type: :team)
    assert_equal NEW, account.voice_embedding_profile
    assert FieldVoiceprints::Conversion.ready?(account)
    assert_equal "ready", FieldVoiceprints::Conversion.presentation(account)[:state]
    assert_equal OLD, @account.reload.voice_embedding_profile, "existing references still need conversion"
  end

  test "conversion writes only the embedding/profile pair and encrypted rollback pair" do
    sample = @samples.first
    before = sample.attributes
    old = sample.embedding
    assert_equal :converted, convert(sample)
    after = sample.reload.attributes
    changed = before.keys.select { |key| before[key] != after[key] }
    assert_equal %w[embedding profile rollback_embedding rollback_profile], changed.sort
    assert_equal old, sample.rollback_embedding
    assert_equal OLD, sample.rollback_profile
    assert_equal 256, sample.vector_for(NEW).size
    assert_equal 192, sample.vector_for(OLD).size
    raw = FieldVoiceSample.connection.select_value("SELECT rollback_embedding FROM field_voice_samples WHERE id = #{sample.id}")
    assert_not_equal old, raw, "the rollback biometric is encrypted too"
    assert sample.manually_confirmed?
  end

  test "runtime readiness reads persisted conversion state without inspecting samples" do
    @account.update!(voice_embedding_profile: NEW, voice_conversion_status: "ready")
    FieldVoiceprints::Conversion.stub(:candidates, ->(*) { flunk "runtime gate must not inspect biometrics" }) do
      assert FieldVoiceprints::Conversion.ready?(@account)
      assert_equal "ready", FieldVoiceprints::Conversion.presentation(@account)[:state]
      %w[converting blocked].each do |state|
        @account.update!(voice_conversion_status: state)
        assert_not FieldVoiceprints::Conversion.ready?(@account)
      end
      @account.update!(voice_conversion_status: nil)
      assert FieldVoiceprints::Conversion.ready?(@account), "accounts need not have run a conversion already"
      @account.update!(voice_embedding_profile: OLD)
      assert_not FieldVoiceprints::Conversion.ready?(@account)
    end
  end

  test "a source discarded after activation drops its own reference without pausing the account" do
    recording = long_ready_recording(account: @account, user: @user)
    sample = @samples.first
    sample.update!(field_recording: recording)
    digest = FieldVoiceSamples::Uploads.source_digest(sample)
    sample.update!(source_digest: digest, confirmed_digest: digest)
    other = @account.field_voices.create!(name: "Unaffected synthetic voice")
    store_print!(other)
    assert_equal :activated, FieldVoiceprints::Conversion.run!(@account, client: client)
    other.voiceprint.update!(validated: true)
    restamp_cohort!(@account)
    assert_includes FieldVoiceprints::Cohort.active(@account).first.map(&:field_voice_id), other.id

    assert recording.discard_and_settle!
    assert_not sample.reload.manually_confirmed?
    assert FieldVoiceprints::Conversion.ready?(@account.reload)
    assert_equal "ready", FieldVoiceprints::Conversion.presentation(@account)[:state]
    # The ordinary cohort stamp still changes when a print loses a reference;
    # stand in for its normal revalidation, not an engine conversion.
    restamp_cohort!(@account)
    assert_includes FieldVoiceprints::Cohort.active(@account).first.map(&:field_voice_id), other.id
    assert_not_includes FieldVoiceprints::Cohort.prints(@account).map(&:field_voice_id), @voice.id
    assert_no_enqueued_jobs(only: FieldVoices::ConvertProfileJob) do
      @voice.with_lock { FieldVoiceprints::Learning.rebuild!(@voice) }
    end
    assert_nil @voice.reload.voiceprint
    @account.update!(voice_conversion_status: nil)
    FieldVoiceprints::Conversion.stub(:candidates, ->(*) { flunk "an active legacy account must not restart conversion" }) do
      assert_equal :ready, FieldVoiceprints::Conversion.run!(@account, client: client)
    end
    assert_nil @account.reload.voice_conversion_status
    with_recognition(@account) do
      probe = long_ready_recording(account: @account, user: @user)
      assert_kind_of Integer, FieldVoiceprints::Identification.run!(probe, client: client)
    end
  end

  test "interruption resumes without redoing converted rows and preserves old print until atomic activation" do
    print = @voice.voiceprint
    before = print.attributes
    assert_equal :converted, convert(@samples.first)
    assert_equal before, print.reload.attributes
    assert_equal OLD, FieldVoiceprints::Cohort.profile(@account)
    assert_equal [ print.id ], FieldVoiceprints::Cohort.prints(@account).map(&:id)
    assert_empty FieldVoiceprints::Cohort.active(@account).first
    assert_equal :blocked, FieldVoiceprints::Conversion.activate!(@account, target: NEW)
    assert_equal before, print.reload.attributes
    using = client
    assert_equal :activated, FieldVoiceprints::Conversion.run!(@account, client: using)
    assert_equal 1, using.calls.size, "only the unfinished sample ran inference"
    assert_equal NEW, @account.reload.voice_embedding_profile
    assert_equal NEW, @voice.reload.voiceprint.profile
    assert_not @voice.voiceprint.validated?
    assert FieldVoiceprints::Conversion.ready?(@account)
    assert_equal :ready, FieldVoiceprints::Conversion.run!(@account, client: using)
    assert_equal 1, using.calls.size
  end

  test "rollback is an offline pair swap and a forward roundtrip needs no inference" do
    using = client
    assert_equal :activated, FieldVoiceprints::Conversion.run!(@account, client: using)
    old_vectors = @samples.map { |sample| sample.reload.vector_for(OLD) }
    Setting.instance.update!(voice_embedding_profile: OLD)
    assert_equal :activated, FieldVoiceprints::Conversion.run!(@account, client: using)
    assert_equal old_vectors, @samples.map { |sample| sample.reload.vector }
    assert_equal OLD, @account.reload.voice_embedding_profile
    assert_equal OLD, @voice.reload.voiceprint.profile
    Setting.instance.update!(voice_embedding_profile: NEW)
    assert_equal :activated, FieldVoiceprints::Conversion.run!(@account, client: using)
    assert_equal 2, using.calls.size
  end

  test "forget while inference runs discards output and both biometric copies" do
    using = client { @voice.forget! }
    assert_equal :gone, FieldVoiceprints::Conversion.convert!(@samples.first, target: NEW, client: using)
    assert_empty @voice.samples
    assert_nil @voice.reload.voiceprint
    assert_equal :activated, FieldVoiceprints::Conversion.activate!(@account, target: NEW)
  end

  test "removal while inference runs cannot recreate a rollback vector" do
    sample = @samples.first
    using = client { sample.remove!(digest: sample.source_digest, by: @user) }
    assert_equal :stale, convert(sample, using)
    assert_nil sample.reload.rollback_embedding
    assert_nil sample.rollback_profile
    assert_not sample.eligible?
  end

  test "reattribution while inference runs cannot publish into the other voice" do
    sample = @samples.first
    target = @account.field_voices.create!(name: "Other synthetic voice")
    using = client { sample.reattribute!(voice: target, digest: sample.source_digest, by: @user) }
    assert_equal :stale, convert(sample, using)
    assert_equal target.id, sample.reload.field_voice_id
    assert_nil sample.rollback_embedding
  end

  test "concurrent converters cannot overwrite the known-good rollback copy" do
    sample = @samples.first
    nested = client
    using = client { assert_equal :converted, convert(sample, nested) }
    assert_equal :stale, convert(sample, using)
    assert_equal OLD, sample.reload.rollback_profile
  end

  test "unconfirmed and excluded rows are never enrolled by conversion" do
    @samples.first.update!(eligible: false, excluded: true)
    @samples.last.update!(confirmed_digest: nil, confirmed_by: nil, confirmed_at: nil)
    using = client
    assert_equal :activated, FieldVoiceprints::Conversion.run!(@account, client: using)
    assert_empty using.calls
    assert @samples.all? { |sample| sample.reload.profile == OLD }
    assert_nil @voice.reload.voiceprint
  end

  test "missing retained audio blocks activation and removing the row unblocks retry" do
    sample = @samples.first
    blob = sample.audio.blob
    blob.service.delete(blob.key)
    assert_equal :blocked, FieldVoiceprints::Conversion.run!(@account, client: client)
    assert_equal OLD, @account.reload.voice_embedding_profile
    assert_equal "blocked", FieldVoiceprints::Conversion.presentation(@account)[:state]
    assert @voice.reload.voiceprint
    sample.remove!(digest: sample.source_digest, by: @user)
    assert_equal :activated, FieldVoiceprints::Conversion.run!(@account, client: client)
    assert FieldVoiceprints::Conversion.ready?(@account.reload)
  end

  test "a changed source blocks rather than silently dropping its listening receipt" do
    @samples.first.update_columns(source_session: "changed")
    using = client
    assert_equal :blocked, FieldVoiceprints::Conversion.run!(@account, client: using)
    assert_equal OLD, @account.reload.voice_embedding_profile
    assert_equal 1, using.calls.size
  end

  test "a review during inference wins even if it later includes the same bytes again" do
    sample = @samples.first
    using = client { sample.review!(digest: sample.source_digest, by: @user, included: true) }
    assert_equal :stale, convert(sample, using)
    assert_equal OLD, sample.reload.profile
    assert_nil sample.rollback_embedding
  end

  test "a new naming learned mid-conversion cannot flip the profile or destroy the ECAPA print" do
    recording = long_ready_recording(account: @account, user: @user)
    with_recognition(@account) do
      speaker = recording.speakers.find_by!(label: "speaker_0")
      speaker.name_as!(@voice, by: @user)
      snapshot = FieldVoiceprints::Learning.snapshot_for(speaker.reload)
      fake = client
      Tempfile.create("synthetic") do |file|
        file.write("synthetic")
        file.flush
        FieldVoiceprints::Sample.stub(:cut, ->(_recording, _spans, &block) { block.call(file.path) }) do
          assert_equal :learned, FieldVoiceprints::Learning.learn!(snapshot, client: fake)
        end
      end
      assert_equal NEW, speaker.voice_samples.sole.profile
      assert_equal OLD, @voice.reload.voiceprint.profile
      assert_equal OLD, FieldVoiceprints::Cohort.profile(@account)
    end
  end

  test "activation removes incompatible cached probes and stale guesses" do
    recording = long_ready_recording(account: @account, user: @user)
    speaker = recording.speakers.first
    speaker.update!(probe_embedding: JSON.generate(voice_vector(0)), probe_profile: OLD,
      recognised_voice: @voice, recognition_confidence: 99, recognition_print_generation: @voice.print_generation)
    generation = @account.field_probe_generation
    assert_equal :activated, FieldVoiceprints::Conversion.run!(@account, client: client)
    assert_nil speaker.reload.probe_embedding
    assert_nil speaker.probe_profile
    assert_nil speaker.recognised_voice_id
    assert_operator @account.reload.field_probe_generation, :>, generation
  end

  test "recording-backed conversion cuts the persisted montage, never selects fresh spans" do
    recording = long_ready_recording(account: @account, user: @user)
    sample = confirmed_recording_sample!(@voice, recording:, vector: voice_vector(0))
    before = sample.attributes
    cutter = lambda do |source, spans, &block|
      assert_equal recording.id, source.id
      assert_equal sample.source_segments, spans
      Tempfile.create("synthetic") do |file|
        file.write("synthetic audio")
        file.flush
        block.call(file.path)
      end
    end
    FieldVoiceprints::Sample.stub(:segments_for, ->(*) { flunk "must not reselect confirmed speech" }) do
      FieldVoiceprints::Sample.stub(:cut, cutter) { assert_equal :converted, convert(sample) }
    end
    assert_equal before.except("embedding", "profile", "rollback_embedding", "rollback_profile"),
      sample.reload.attributes.except("embedding", "profile", "rollback_embedding", "rollback_profile")
    assert sample.manually_confirmed?
  end

  test "ordinary relearning cannot overwrite a confirmed old-engine reference" do
    recording = long_ready_recording(account: @account, user: @user)
    with_recognition(@account) do
      sample = confirmed_recording_sample!(@voice, recording:, vector: voice_vector(0))
      speaker = sample.field_recording_speaker
      snapshot = FieldVoiceprints::Learning.snapshot_for(speaker)
      assert snapshot
      before = sample.attributes
      Tempfile.create("synthetic") do |file|
        file.write("synthetic")
        file.flush
        FieldVoiceprints::Sample.stub(:segments_for, sample.source_segments) do
          FieldVoiceprints::Sample.stub(:cut, ->(_recording, _spans, &block) { block.call(file.path) }) do
            assert_equal :stale, FieldVoiceprints::Learning.learn!(snapshot, client: client)
          end
        end
      end
      assert_equal before, sample.reload.attributes
      assert_nil sample.rollback_embedding
    end
  end

  test "forget all and restore reset remove rollback biometrics as well" do
    convert(@samples.first)
    FieldVoiceprints.forget_all!(@account)
    assert_empty FieldVoiceSample.where(account: @account)
    assert_equal 0, FieldVoiceSample.where.not(rollback_embedding: nil).count
    assert_nothing_raised { FieldVoiceprints.reset_all! }
  end

end
