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
      assert review(sample, included: true)
      retained = confirmed_recording_sample!(@voice,
        recording: long_ready_recording(account: @account, user: @user), vector: voice_vector(3))
      assert_equal 2, @voice.reload.voiceprint.sample_count
      sample.update!(source_segments: nil, source_digest: nil)
      assert_not sample.source_current?
      assert_not sample.manually_confirmed?
      assert_not review(sample, included: true)
      print = @voice.reload.voiceprint
      assert_empty FieldVoiceprints::Cohort.prints(@account), "retained legacy inclusion is not confirmed testimony"
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
      assert_not sample.eligible?, "the replacement cut waits for exact review"
      assert retained.reload.eligible?
      assert retained.manually_confirmed?
      assert_nil @voice.reload.voiceprint, "one retained confirmation cannot form a print"
    end
  end

  test "last exclusion removes the actual print and preserves confirmation" do
    with_recognition(@account) do
      sample = enrolled_sample
      retained = confirmed_recording_sample!(@voice,
        recording: long_ready_recording(account: @account, user: @user), vector: voice_vector(3))
      assert review(sample, included: true)
      assert_equal 2, @voice.reload.voiceprint.sample_count
      confirmed_at = @speaker.reload.sample_confirmed_at
      assert review(sample, included: false)
      assert @speaker.reload.sample_excluded?
      assert_not sample.reload.eligible?
      assert_nil @voice.reload.voiceprint
      assert retained.reload.eligible?
      assert retained.manually_confirmed?
      assert_equal confirmed_at, @speaker.sample_confirmed_at
      assert sample.manually_confirmed?
      assert review(sample, included: true)
      assert sample.reload.eligible?
      assert_equal 2, @voice.reload.voiceprint.sample_count
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
        FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: @vector, profile: FieldVoiceprints::Profiles::ECAPA)
      end
      client.instance_variable_set(:@review, -> { assert review(nil, included: false) })
      client.instance_variable_set(:@vector, voice_vector(3))
      assert_equal :stale, learn(snapshot, client:)
      assert_empty FieldVoiceSample.where(field_recording_speaker: @speaker)
      assert_nil @voice.reload.voiceprint
      assert @speaker.reload.sample_excluded?
    end
  end

  test "same voice stays excluded through drop attribution correction line edits and backfill" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert review(sample, included: false)
      @recording.reload.send(:invalidate_speaker_evidence!, [ @speaker.label ])
      assert @speaker.reload.sample_excluded?
      assert_empty @speaker.voice_samples
      assert_no_enqueued_jobs(only: FieldVoices::LearnSampleJob) { @speaker.name_as!(@voice, by: @user) }
      assert_equal 0, FieldVoiceprints::Learning.queue_account!(@account)
      assert @speaker.reload.sample_excluded?
      assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker)
    end
  end

  test "correcting attribution to a different voice clears the previous voice exclusion" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert review(sample, included: false)
      old_snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload, allow_excluded: true)
      other_voice = @account.field_voices.create!(name: "Another")

      assert_enqueued_with(job: FieldVoices::LearnSampleJob) { @speaker.name_as!(other_voice, by: @user) }
      assert_not @speaker.reload.sample_excluded?
      assert_equal :stale, learn(old_snapshot)
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker)
      assert snapshot
      assert_equal other_voice.id, snapshot["voice_id"]
      assert_equal :learned, learn(snapshot)
      assert_equal other_voice.id, @speaker.voice_samples.sole.field_voice_id
      assert_not @speaker.voice_samples.sole.eligible?, "corrected attribution is a new unreviewed candidate"
      assert_not @speaker.voice_samples.sole.manually_confirmed?
      assert_nil other_voice.reload.voiceprint
      assert review(@speaker.voice_samples.sole, included: true)
      assert @speaker.voice_samples.sole.reload.eligible?
      assert_nil other_voice.reload.voiceprint, "one exact confirmation remains insufficient"
      assert_nil @voice.reload.voiceprint
    end
  end

  test "text only correction preserves confirmation of the exact heard audio" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert review(sample, included: true)
      digest = sample.source_digest
      segments = sample.source_segments.deep_dup
      blob_id = @recording.audio.blob.id
      generation = @speaker.reload.decision_generation
      line = @recording.reload.transcript_lines.first

      @recording.correct_line!(line[:locator], text: "first corrected", was: line[:text],
        revision: @recording.transcript_revision)

      assert_includes @recording.reload.transcript_text, "first corrected"
      assert_equal generation, @speaker.reload.decision_generation
      assert_equal blob_id, @recording.audio.blob.id
      assert_equal digest, sample.reload.source_digest
      assert_equal segments, sample.source_segments
      assert sample.source_current?
      assert sample.manually_confirmed?
    end
  end

  test "source evidence generation changes invalidate confirmation and in flight writes" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert review(sample, included: true)
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
      @speaker.increment!(:decision_generation)
      assert_not sample.source_current?
      assert_not sample.manually_confirmed?
      assert_not review(sample, included: true)
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
      result = FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: voice_vector(3), profile: FieldVoiceprints::Profiles::ECAPA)
      client = Object.new
      change = -> {
        @speaker.increment!(:decision_generation)
      }
      client.define_singleton_method(:embed) { |_wav| change.call; result }
      assert_equal :stale, learn(snapshot, client:)
      assert_empty @speaker.voice_samples
      assert_nil @voice.reload.voiceprint
    end
  end

  test "new extractions and reviews cannot select the account profile" do
    with_recognition(@account) do
      sample = enrolled_sample
      sample.update!(updated_at: 1.day.ago)
      confirmed_recording_sample!(@voice,
        recording: long_ready_recording(account: @account, user: @user), vector: voice_vector(3))
      assert review(sample, included: true)
      assert_equal FieldVoiceprints::Profiles::ECAPA, @voice.reload.voiceprint.profile
      other = long_ready_recording(account: @account, user: @user).speakers.find_by!(label: "speaker_0")
      other.name_as!(@voice, by: @user)
      snapshot = FieldVoiceprints::Learning.snapshot_for(other.reload)
      assert_equal :learned, learn(snapshot)
      assert_equal FieldVoiceprints::Profiles::ECAPA, @voice.reload.voiceprint.profile
      current = other.voice_samples.sole
      current.update_columns(profile: FieldVoiceprints::Profiles::WESPEAKER,
        embedding: JSON.generate([ 1.0 ] + [ 0.0 ] * 255))
      assert other.review_sample!(sample: current, digest: current.source_digest, by: @user, included: true)
      assert_equal FieldVoiceprints::Profiles::ECAPA, @voice.reload.voiceprint.profile,
        "confirming a different engine does not destroy or flip the old active print"
      confirmed_recording_sample!(@voice,
        recording: long_ready_recording(account: @account, user: @user), vector: voice_vector(3))
      assert_equal FieldVoiceprints::Profiles::ECAPA, @voice.reload.voiceprint.profile

      extracted_at = sample.reload.updated_at
      assert review(sample, included: true)
      assert_equal extracted_at, sample.reload.updated_at
      assert_equal FieldVoiceprints::Profiles::ECAPA, @voice.reload.voiceprint.profile
      assert_equal 3, @voice.voiceprint.sample_count
    end
  end

  test "provider failures expose a safe error and a fresh retry clears it" do
    with_recognition(@account) do
      sample = enrolled_sample
      assert review(sample, included: true)
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
        result = FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: voice_vector(3), profile: FieldVoiceprints::Profiles::ECAPA)
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
