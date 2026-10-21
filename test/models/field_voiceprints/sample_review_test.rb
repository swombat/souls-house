require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceprints::SampleReviewTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker = @recording.speakers.find_by!(label: "speaker_0")
    @voice = @account.field_voices.create!(name: "Tomás")
  end

  def fake_cut(&)
    FieldVoiceprints::Sample.stub(:cut, ->(_recording, _segments, &block) {
      Tempfile.create([ "review", ".wav" ]) { |file| file.write("RIFF"); file.flush; block.call(file.path) }
    }, &)
  end

  def learn(snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload), client: nil)
    fake_cut do
      FieldVoiceprints::Learning.learn!(snapshot,
        client: client || FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
    end
  end

  def enrolled_sample
    @speaker.name_as!(@voice, by: @user)
    assert_equal :learned, learn
    FieldVoiceSample.find_by!(field_recording_speaker: @speaker)
  end

  def review(sample, included:, digest: sample&.source_digest)
    @speaker.review_sample!(sample:, digest:, by: @user, included:)
  end

  test "confirmation binds the exact persisted montage and never accepts a stale digest" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert_equal [ [ 0, 12_000 ], [ 17_000, 22_000 ] ], sample.source_segments
      assert sample.source_current?
      assert_not sample.manually_confirmed?
      assert_not review(sample, included: true, digest: "another montage")
      assert review(sample, included: true)
      assert sample.manually_confirmed?
      assert_equal sample.source_digest, @speaker.reload.sample_confirmed_digest
      assert_equal @user, @speaker.sample_confirmed_by

      # A digest also covers ordering and exact span endpoints.
      sample.update!(source_segments: sample.source_segments.reverse)
      assert_not sample.source_current?
      assert_not review(sample, included: true)
    end
  end

  test "legacy samples remain included during refresh and cannot be confirmed" do
    with_recognition(@account) do
      sample = enrolled_sample
      sample.update!(source_segments: nil, source_digest: nil)
      assert_not sample.source_current?
      assert_not sample.manually_confirmed?
      assert_not review(sample, included: true)
      print = @voice.reload.voiceprint
      assert_equal 0, FieldVoiceprints::Learning.queue_account!(@account),
        "backfill leaves legacy samples alone"
      assert sample.reload.eligible?

      assert_enqueued_with(job: FieldVoices::LearnSampleJob) { assert @speaker.relearn_sample! }
      assert sample.reload.eligible?
      assert_equal print.id, @voice.reload.voiceprint.id
      assert_equal "pending", @speaker.reload.sample_learning_status
      assert_equal :learned, learn
      assert sample.reload.source_current?
      assert_not sample.manually_confirmed?, "refresh is not a person's approval"
    end
  end

  test "last exclusion removes the actual print and preserves confirmation" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert review(sample, included: true)
      confirmed_at = @speaker.reload.sample_confirmed_at
      assert review(sample, included: false)
      assert @speaker.reload.sample_excluded?
      assert_not sample.reload.eligible?
      assert_nil @voice.reload.voiceprint
      assert_equal confirmed_at, @speaker.sample_confirmed_at
      assert sample.manually_confirmed?
      assert review(sample, included: true)
      assert sample.reload.eligible?
      assert_equal 1, @voice.reload.voiceprint.sample_count
    end
  end

  test "deleting a confirming user nullifies attribution without blocking deletion" do
    with_recognition(@account) do
      sample = enrolled_sample
      confirmer = User.create!(email_address: "sample-reviewer@example.com", password: "password123")
      assert @speaker.review_sample!(sample:, digest: sample.source_digest, by: confirmer, included: true)
      assert sample.manually_confirmed?

      confirmer.destroy!
      assert_nil @speaker.reload.sample_confirmed_by_id
      assert_equal sample.source_digest, @speaker.sample_confirmed_digest
      assert_not sample.manually_confirmed?, "a deleted confirmer cannot remain attributed approval"
    end
  end

  test "legacy exclusion is allowed and explicit excluded refresh never enrolls" do
    with_recognition(@account) do
      sample = enrolled_sample
      sample.update!(source_segments: nil, source_digest: nil)
      assert review(sample, included: false)
      assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
      assert @speaker.relearn_sample!
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload, allow_excluded: true)
      assert_equal :learned, learn(snapshot)
      assert sample.reload.source_current?
      assert_not sample.eligible?
      assert @speaker.reload.sample_excluded?
      assert_nil @voice.reload.voiceprint
      assert review(sample, included: true)
      assert sample.reload.eligible?
    end
  end

  test "legacy exclusion and exact confirmation do not depend on cluster naming provenance" do
    with_recognition(@account) do
      sample = enrolled_sample
      @speaker.update!(naming_source: "unknown")
      assert review(sample, included: true)
      assert sample.reload.manually_confirmed?
      assert_equal "unknown", @speaker.reload.naming_source
      assert_not @speaker.relearn_sample!, "refresh still requires a training label"
      sample.update!(source_segments: nil, source_digest: nil)
      assert review(sample, included: false)
      assert @speaker.reload.sample_excluded?
      assert_nil @voice.reload.voiceprint
    end
  end

  test "exclusion during the first embedding invalidates the job" do
    with_recognition(@account) do
      @speaker.name_as!(@voice, by: @user)
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
      client = Object.new
      client.define_singleton_method(:embed) do |_wav|
        @review.call
        FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: @vector, profile: "ecapa-test")
      end
      client.instance_variable_set(:@review, -> { assert review(nil, included: false) })
      client.instance_variable_set(:@vector, voice_vector(3))
      assert_equal :stale, learn(snapshot, client:)
      assert_empty FieldVoiceSample.where(field_recording_speaker: @speaker)
      assert_nil @voice.reload.voiceprint
      assert @speaker.reload.sample_excluded?
    end
  end

  test "excluded speakers stay excluded through drop rename line edits and backfill" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert review(sample, included: false)
      @recording.reload.send(:invalidate_speaker_evidence!, [ @speaker.label ])
      assert @speaker.reload.sample_excluded?
      assert_empty @speaker.voice_samples
      other_voice = @account.field_voices.create!(name: "Another")
      assert_no_enqueued_jobs(only: FieldVoices::LearnSampleJob) { @speaker.name_as!(other_voice, by: @user) }
      assert_equal 0, FieldVoiceprints::Learning.queue_account!(@account)
      assert @speaker.reload.sample_excluded?
      assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker)
    end
  end

  test "source evidence changes invalidate confirmation and in flight writes" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert review(sample, included: true)
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
      original_words = @recording.reload.transcript_words.deep_dup
      changed = original_words.deep_dup
      changed.first["t"] = "edited word"
      @recording.update!(transcript_words: changed)
      assert_not sample.source_current?
      assert_not sample.manually_confirmed?
      assert_not review(sample, included: true)
      assert_equal :stale, learn(snapshot)

      @recording.update!(transcript_words: original_words)
      assert sample.source_current?
      @speaker.increment!(:decision_generation)
      assert_not sample.source_current?
      assert_equal :stale, learn(snapshot)
    end
  end

  test "changing the audio blob invalidates the source" do
    with_recognition(@account) do
      sample = enrolled_sample
      @recording.audio.attach(pinned_blob(account: @account, user: @user))
      assert_not sample.source_current?
      assert_not review(sample, included: true)
    end
  end

  test "evidence changed during embedding refuses the write" do
    with_recognition(@account) do
      @speaker.name_as!(@voice, by: @user)
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
      result = FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: voice_vector(3), profile: "ecapa-test")
      client = Object.new
      change = -> {
        words = @recording.reload.transcript_words.deep_dup
        words.first["t"] = "changed during embedding"
        @recording.update!(transcript_words: words)
      }
      client.define_singleton_method(:embed) { |_wav| change.call; result }
      assert_equal :stale, learn(snapshot, client:)
      assert_empty @speaker.voice_samples
      assert_nil @voice.reload.voiceprint
    end
  end

  test "reviewing an older profile does not make it the newest extraction" do
    with_recognition(@account) do
      sample = enrolled_sample
      sample.update!(profile: "ecapa-old", updated_at: 1.day.ago)
      other = long_ready_recording(account: @account, user: @user).speakers.find_by!(label: "speaker_0")
      other.name_as!(@voice, by: @user)
      snapshot = FieldVoiceprints::Learning.snapshot_for(other.reload)
      assert_equal :learned, learn(snapshot)
      assert_equal "ecapa-test", @voice.reload.voiceprint.profile

      extracted_at = sample.reload.updated_at
      assert review(sample, included: true)
      assert_equal extracted_at, sample.reload.updated_at
      assert_equal "ecapa-test", @voice.reload.voiceprint.profile
      assert_equal 1, @voice.voiceprint.sample_count
    end
  end

  test "provider failures expose a safe error and a fresh retry clears it" do
    with_recognition(@account) do
      sample = enrolled_sample
      sample.update!(source_segments: nil, source_digest: nil)
      assert @speaker.relearn_sample!
      old_snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
      failing = FakeVoiceEmbeddings.new(fail_with: FieldVoiceprints::VoiceEmbeddings::Unavailable.new("private provider details"))
      error = assert_raises(FieldVoiceprints::VoiceEmbeddings::Unavailable) { learn(old_snapshot, client: failing) }
      assert_not_includes error.message, "private"
      assert_equal "error", @speaker.reload.sample_learning_status
      assert_not_includes @speaker.sample_learning_error, "private"
      assert sample.reload.eligible?, "failure does not silently remove a legacy enrollment"

      assert @speaker.relearn_sample!
      assert_equal "pending", @speaker.reload.sample_learning_status
      assert_nil @speaker.sample_learning_error
      assert_equal :stale, learn(old_snapshot)
      assert_equal :learned, learn
      assert_equal "learned", @speaker.reload.sample_learning_status
      assert_nil @speaker.sample_learning_error
      assert_not sample.reload.manually_confirmed?
    end
  end

  test "insufficient clean speech is recorded without leaking extractor details" do
    with_recognition(@account) do
      @speaker.name_as!(@voice, by: @user)
      FieldVoiceprints::Sample.stub(:segments_for, ->(_) { raise FieldVoiceprints::Sample::Refused, "not for display" }) do
        assert_equal :no_sample, learn
      end
      assert_equal "no_sample", @speaker.reload.sample_learning_status
      assert_nil @speaker.sample_learning_error
    end
  end

  test "the existing job retries a provider failure with safe status and the same snapshot" do
    with_recognition(@account) do
      @speaker.name_as!(@voice, by: @user)
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
      fake_cut do
        FieldVoiceprints::VoiceEmbeddings.stub(:embed, ->(_) {
          raise FieldVoiceprints::VoiceEmbeddings::Unavailable, "private provider detail"
        }) do
          assert_enqueued_with(job: FieldVoices::LearnSampleJob, args: [ snapshot ]) do
            FieldVoices::LearnSampleJob.perform_now(snapshot)
          end
        end
        assert_equal "error", @speaker.reload.sample_learning_status
        result = FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: voice_vector(3), profile: "ecapa-test")
        FieldVoiceprints::VoiceEmbeddings.stub(:embed, ->(_) { result }) do
          FieldVoices::LearnSampleJob.perform_now(snapshot)
        end
      end
      assert_equal "learned", @speaker.reload.sample_learning_status
      assert_nil @speaker.sample_learning_error
      assert_equal 1, @speaker.voice_samples.count
    end
  end

  test "missing source audio is a visible failure rather than endless pending" do
    with_recognition(@account) do
      @speaker.name_as!(@voice, by: @user)
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
      FieldVoiceprints::Sample.stub(:cut, ->(*) { raise ActiveStorage::FileNotFoundError }) do
        assert_equal :no_sample, FieldVoiceprints::Learning.learn!(snapshot)
      end
      assert_equal "error", @speaker.reload.sample_learning_status
      assert_match(/source audio is unavailable/, @speaker.sample_learning_error)
      @recording.audio.detach
      assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
    end
  end

end
