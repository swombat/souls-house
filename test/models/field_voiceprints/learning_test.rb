require "test_helper"
require "support/field_recording_helpers"

# Learning prints from people's namings (spec 2026-10-19 §4, §6, §9): what is
# learned, from whom, and that anything a person does meanwhile wins.
class FieldVoiceprints::LearningTest < ActiveSupport::TestCase

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
      Tempfile.create([ "s", ".wav" ]) { |file| file.write("RIFF"); file.flush; block.call(file.path) }
    }, &)
  end

  def learn(snapshot, vector: voice_vector(3))
    fake_cut { FieldVoiceprints::Learning.learn!(snapshot, client: FakeVoiceEmbeddings.new({ default: vector })) }
  end

  def named_snapshot(speaker = @speaker, voice = @voice, source: "human")
    speaker.name_as!(voice, by: @user, source:)
    FieldVoiceprints::Learning.snapshot_for(speaker.reload)
  end

  def confirm_sample(speaker = @speaker)
    sample = FieldVoiceSample.find_by!(field_recording_speaker: speaker)
    assert speaker.reload.review_sample!(sample:, digest: sample.source_digest, by: @user, included: true)
    sample.reload
  end

  test "a person's naming queues a candidate and two exact reviews create an unchecked print" do
    with_recognition(@account) do
      assert_enqueued_with(job: FieldVoices::LearnSampleJob) { @speaker.name_as!(@voice, by: @user) }
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)

      assert_equal :learned, learn(snapshot)
      sample = FieldVoiceSample.sole
      assert_equal [ @voice.id, @speaker.id, @recording.id ], [ sample.field_voice_id, sample.field_recording_speaker_id, sample.field_recording_id ]
      assert_equal 17_000, sample.speech_ms
      assert_not sample.eligible
      assert_not sample.manually_confirmed?
      assert_equal "human", sample.label_origin
      assert_nil @voice.reload.voiceprint
      assert confirm_sample.manually_confirmed?
      assert_nil @voice.reload.voiceprint, "one exact confirmation is not enough"

      second = long_ready_recording(account: @account, user: @user).speakers.find_by!(label: "speaker_0")
      assert_equal :learned, learn(named_snapshot(second))
      assert_nil @voice.reload.voiceprint, "a second unreviewed candidate is not testimony"
      confirm_sample(second)

      print = @voice.reload.voiceprint
      assert_equal @voice.print_generation, print.generation
      assert_equal [ 2, 2 ], [ print.sample_count, print.recording_count ]
      assert_in_delta 1.0, FieldVoiceprints.cosine(print.vector, voice_vector(3)), 1e-9
      assert_not_includes FieldVoiceprints::Identification.active_prints(@account), print,
        "a new print is unchecked until validation runs"
      assert_raises(NotImplementedError) { print.as_json }
      assert_raises(NotImplementedError) { sample.as_json }
    end
  end

  test "a machine's naming never teaches a print" do
    with_recognition(@account) do
      assert_no_enqueued_jobs(only: FieldVoices::LearnSampleJob) { @speaker.name_as!(@voice, by: nil, source: "machine") }
      assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
    end
  end

  test "nothing is learned while recognition is off, or before the writer cutover is recorded" do
    with_recognition(@account) do
      @account.update!(recognise_voices: false)
      assert_nil named_snapshot
      @account.update!(recognise_voices: true)
      Setting.instance.update!(field_naming_cutover_at: nil)
      assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker.reload)
    end
  end

  test "un-naming while the embedding is in flight writes nothing" do
    with_recognition(@account) do
      snapshot = named_snapshot
      @speaker.unname!
      assert_equal :stale, learn(snapshot)
      assert_equal 0, FieldVoiceSample.count
    end
  end

  test "Forget while in flight writes nothing, and neither does the old job after Remember again" do
    with_recognition(@account) do
      snapshot = named_snapshot
      @voice.forget!
      assert_equal :stale, learn(snapshot)

      @voice.remember_again!
      assert_equal :stale, learn(snapshot), "queued before the forget, so it may never write"
      assert_equal 0, FieldVoiceSample.count

      assert_equal :learned, learn(FieldVoiceprints::Learning.snapshot_for(@speaker.reload)), "a fresh snapshot learns"
    end
  end

  test "duplicate delivery writes one sample" do
    with_recognition(@account) do
      snapshot = named_snapshot
      2.times { assert_equal :learned, learn(snapshot) }
      assert_equal 1, FieldVoiceSample.count
    end
  end

  test "two samples landing in either order give the same print" do
    with_recognition(@account) do
      second = long_ready_recording(account: @account, user: @user)
      other = second.speakers.find_by!(label: "speaker_0")
      a = named_snapshot
      b = named_snapshot(other)
      vectors = { a => voice_vector(3, noise: 0.4, seed: 1), b => voice_vector(3, noise: 0.4, seed: 2) }

      [ [ a, b ], [ b, a ] ].map do |order|
        FieldVoiceSample.delete_all
        order.each do |snapshot|
          speaker = FieldRecordingSpeaker.find(snapshot["speaker_id"])
          assert_equal :learned, learn(FieldVoiceprints::Learning.snapshot_for(speaker), vector: vectors[snapshot])
          confirm_sample(speaker)
        end
        print = @voice.reload.voiceprint
        assert_equal [ 2, 2 ], [ print.sample_count, print.recording_count ]
        print.vector
      end => [ first, again ]
      first.zip(again).each { |x, y| assert_in_delta x, y, 1e-12 }
    end
  end

  test "un-naming and renaming drop the sample and rebuild the print without it" do
    with_recognition(@account) do
      second = long_ready_recording(account: @account, user: @user)
      other = second.speakers.find_by!(label: "speaker_0")
      third = long_ready_recording(account: @account, user: @user).speakers.find_by!(label: "speaker_0")
      learn(named_snapshot)
      confirm_sample
      learn(named_snapshot(other))
      confirm_sample(other)
      learn(named_snapshot(third))
      confirm_sample(third)
      assert_equal 3, @voice.reload.voiceprint.sample_count

      other.reload.unname!
      assert_equal [ 2, 2 ], [ @voice.reload.voiceprint.sample_count, FieldVoiceSample.count ]

      elsewhere = @account.field_voices.create!(name: "Priya")
      @speaker.reload.name_as!(elsewhere, by: @user)
      assert_nil @voice.reload.voiceprint, "one retained confirmed sample is insufficient"
      assert_equal 1, FieldVoiceSample.count
      assert FieldVoiceSample.sole.manually_confirmed?, "the remaining evidence is not erased"
    end
  end

  test "discarding a recording drops its samples" do
    with_recognition(@account) do
      learn(named_snapshot)
      @recording.reload.discard_and_settle!
      assert_equal 0, FieldVoiceSample.count
      assert_nil @voice.reload.voiceprint
    end
  end

  test "moving a line throws the speaker's sample away and learns again" do
    with_recognition(@account) do
      learn(named_snapshot)
      assert_equal 1, FieldVoiceSample.count
      assert_enqueued_with(job: FieldVoices::LearnSampleJob) do
        @recording.reload.send(:invalidate_speaker_evidence!, [ "speaker_0" ])
      end
      assert_equal 0, FieldVoiceSample.count
    end
  end

  test "a rebuild clears guesses made from the old print" do
    with_recognition(@account) do
      unnamed = @recording.speakers.find_by!(label: "speaker_1")
      learn(named_snapshot)
      confirm_sample
      second = long_ready_recording(account: @account, user: @user).speakers.find_by!(label: "speaker_0")
      learn(named_snapshot(second))
      confirm_sample(second)
      assert_equal 2, @voice.reload.voiceprint.sample_count
      unnamed.update!(recognised_voice_id: @voice.id, recognition_confidence: 80,
        recognition_print_generation: @voice.reload.print_generation, recognition_decision_generation: 0)

      third = long_ready_recording(account: @account, user: @user)
      learn(named_snapshot(third.speakers.find_by!(label: "speaker_0")))
      assert_nil unnamed.reload.recognised_voice_id
    end
  end

  test "Forget destroys samples and print and stops learning; forget all clears kept embeddings too" do
    with_recognition(@account) do
      learn(named_snapshot)
      @recording.speakers.find_by!(label: "speaker_1").update!(probe_embedding: "[1]", probe_profile: "ecapa-test")

      FieldVoiceprints.forget_all!(@account)
      @voice.reload
      assert_not @voice.remember?
      assert_nil @voice.voiceprint
      assert_equal 0, FieldVoiceSample.count
      assert_nil @recording.speakers.find_by!(label: "speaker_1").probe_embedding
      assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker.reload), "a forgotten voice doesn't learn"
    end
  end

  test "the backfill queues every eligible naming without a sample, once" do
    with_recognition(@account) do
      learn(named_snapshot)
      second = long_ready_recording(account: @account, user: @user)
      second.speakers.find_by!(label: "speaker_0").name_as!(@voice, by: @user)
      second.speakers.find_by!(label: "speaker_1").name_as!(@voice, by: nil, source: "machine")
      clear_enqueued_jobs

      assert_equal 0, FieldVoiceprints::Learning.queue_account!(@account), "already pending work is not queued twice"
      second.speakers.find_by!(label: "speaker_0").update!(sample_learning_status: nil)
      assert_equal 1, FieldVoiceprints::Learning.queue_account!(@account)
      assert_enqueued_jobs 1, only: FieldVoices::LearnSampleJob
    end
  end

end
