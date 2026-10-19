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

  test "a person's naming queues learning, and learning stores a sample and a print" do
    with_recognition(@account) do
      assert_enqueued_with(job: FieldVoices::LearnSampleJob) { @speaker.name_as!(@voice, by: @user) }
      snapshot = FieldVoiceprints::Learning.snapshot_for(@speaker.reload)

      assert_equal :learned, learn(snapshot)
      sample = FieldVoiceSample.sole
      assert_equal [ @voice.id, @speaker.id, @recording.id ], [ sample.field_voice_id, sample.field_recording_speaker_id, sample.field_recording_id ]
      assert_equal 17_000, sample.speech_ms
      assert sample.eligible
      assert_equal "human", sample.label_origin

      print = @voice.reload.voiceprint
      assert_equal @voice.print_generation, print.generation
      assert_equal [ 1, 1 ], [ print.sample_count, print.recording_count ]
      assert_in_delta 1.0, FieldVoiceprints.cosine(print.vector, voice_vector(3)), 1e-9
      assert_not print.active?, "a new print is unchecked until validation runs"
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
        order.each { |snapshot| learn(snapshot, vector: vectors[snapshot]) }
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
      learn(named_snapshot)
      learn(named_snapshot(other))
      assert_equal 2, @voice.reload.voiceprint.sample_count

      other.reload.unname!
      assert_equal [ 1, 1 ], [ @voice.reload.voiceprint.sample_count, FieldVoiceSample.count ]

      elsewhere = @account.field_voices.create!(name: "Priya")
      @speaker.reload.name_as!(elsewhere, by: @user)
      assert_nil @voice.reload.voiceprint, "no samples left, no print"
      assert_equal 0, FieldVoiceSample.count
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
      unnamed.update!(recognised_voice_id: @voice.id, recognition_confidence: 80,
        recognition_print_generation: @voice.reload.print_generation, recognition_decision_generation: 0)

      second = long_ready_recording(account: @account, user: @user)
      learn(named_snapshot(second.speakers.find_by!(label: "speaker_0")))
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

      assert_equal 1, FieldVoiceprints::Learning.queue_account!(@account)
      assert_enqueued_jobs 1, only: FieldVoices::LearnSampleJob
    end
  end

end
