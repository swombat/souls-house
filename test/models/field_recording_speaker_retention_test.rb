require "test_helper"
require "support/field_recording_helpers"

class FieldRecordingSpeakerRetentionTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker = @recording.speakers.find_by!(label: "speaker_1")
    @other = @recording.speakers.find_by!(label: "speaker_0")
    @voice = @account.field_voices.create!(name: "Retained name")
    @speaker.name_as!(@voice, by: @user)
  end

  test "last-line retirement retains the same naming and destroys all evidence" do
    naming = @speaker.reload.attributes.slice("field_voice_id", "naming_source", "named_by_type", "named_by_id", "named_at")
    @speaker.update!(probe_embedding: "[1,2]", probe_profile: "old", auto_named_confidence: 95,
      suggested_voice: @voice, suggested_name: @voice.name, suggestion_quote: "reply", suggestion_quote_ms: 1,
      suggestion_source: "utility", suggested_at: Time.current, suggestion_generation: 1,
      recognised_voice: @voice, recognition_confidence: 90, recognition_print_generation: 1,
      recognition_decision_generation: 1, recognition_cohort: "old", recognition_checked: true,
      sample_confirmed_digest: "old", sample_confirmed_by: @user, sample_confirmed_at: Time.current,
      sample_learning_status: "learned", sample_learning_error: "old")
    sample = FieldVoiceSample.create!(account: @account, field_voice: @voice,
      field_recording_speaker: @speaker, field_recording_id: @recording.id,
      speech_ms: 1000, profile: "ecapa-test", label_origin: "human", eligible: true,
      embedding: JSON.generate(voice_vector(1)), rollback_embedding: JSON.generate(voice_vector(2)),
      rollback_profile: "ecapa-test")

    retire_last_line!

    assert @speaker.reload.retired?
    assert_equal naming, @speaker.attributes.slice(*naming.keys)
    assert_equal "Retained name", @speaker.display_name
    assert @voice.speakers.exists?(@speaker.id), "revocation must still find the retained naming"
    assert_not FieldVoiceSample.exists?(sample.id)
    assert_no_evidence
    assert_not @speaker.training_label?
    assert_not FieldVoiceprints::Identification.undecided?(@speaker)
    assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker)
    assert_not @speaker.relearn_sample!
    assert_not @speaker.review_sample!(sample: nil, digest: nil, by: @user, included: false)
  end

  test "retired speakers are hidden from current views with loaded and unloaded associations" do
    retire_last_line!

    assert_equal [ @other.id ], FieldItems.speakers_of(@recording.reload).map(&:id)
    @recording.speakers.load
    assert_equal [ @other.id ], FieldItems.speakers_of(@recording).map(&:id)
    assert_not_includes @recording.render_transcript_text, "Retained name"
    assert_not_includes @recording.transcript_lines.map { |line| line[:speaker_id] }, @speaker.to_param
    assert_nil @voice.reload.last_named_in
    assert_raises(FieldRecording::LineCorrection::Stale) do
      @recording.reassign_line!(current_line[:locator], to: @speaker, was: current_line[:text],
        revision: @recording.transcript_revision)
    end
  end

  test "new labels and positions skip retired rows but the cap counts active speakers only" do
    retire_last_line!
    # A thousand retired labels must not impose an accidental lifetime cap.
    FieldRecordingSpeaker.insert_all!((2..1000).map do |n|
      { field_recording_id: @recording.id, label: "speaker_#{n}", position: n, retired_at: Time.current }
    end)

    target = @recording.reassign_line!(current_line[:locator], to: :new, was: current_line[:text],
      revision: @recording.transcript_revision)
    assert_equal "speaker_1001", target.label
    assert_equal 1001, target.position
    assert_match FieldRecordingSpeaker::GENERIC_LABEL, target.label
    assert_operator @recording.reload.speakers.active.count, :<=, 2
    assert @speaker.reload.retired?
  end

  test "zero-line restore is explicit and remeasurement can retire the same row again" do
    retire_last_line!
    assert_no_enqueued_jobs only: FieldVoices::LearnSampleJob do
      @speaker.restore!
    end
    assert @speaker.reload.active?
    assert_equal "Retained name", @speaker.display_name
    assert_equal "human", @speaker.naming_source
    assert_equal @user, @speaker.named_by
    assert_equal 0, @speaker.talk_ms
    assert_no_evidence

    @recording.reload.reassign_line!(current_line[:locator], to: @other, was: current_line[:text],
      revision: @recording.transcript_revision)
    assert @speaker.reload.retired?
    assert_no_evidence
  end

  test "atomic recovery assigns a line without learning and rejects stale input without restoring" do
    retire_last_line!
    seen = @recording.reload.transcript_revision
    line = current_line
    [ { was: "wrong", revision: seen }, { was: line[:text], revision: "stale" } ].each do |input|
      assert_raises(FieldRecording::LineCorrection::Stale) do
        @recording.restore_speaker_line!(@speaker, line: line[:locator], **input)
      end
      assert @speaker.reload.retired?
      assert_equal seen, @recording.reload.transcript_revision
    end

    with_recognition(@account) do
      assert_no_enqueued_jobs only: FieldVoices::LearnSampleJob do
        @recording.restore_speaker_line!(@speaker, line: line[:locator],
          was: line[:text], revision: seen)
      end
    end
    assert @speaker.reload.active?
    assert_equal @speaker.label, @recording.reload.transcript_words.first["spk"]
    assert_includes @recording.transcript_text, "Retained name:"
    assert_no_evidence
  end

  test "restoration checks the active cap" do
    retire_last_line!
    (2..FieldRecording::MAX_SPEAKERS).each do |n|
      @recording.speakers.create!(label: "speaker_#{n}", position: n)
    end
    assert_raises(FieldRecording::LineCorrection::Invalid) { @speaker.restore! }
    assert @speaker.reload.retired?
  end

  test "unname while retired cannot be undone by recovery" do
    retire_last_line!
    @speaker.unname!
    @speaker.restore!

    assert_nil @speaker.reload.field_voice_id
    assert_nil @speaker.naming_source
    assert_nil @speaker.named_by_id
    assert_nil @speaker.named_at
    assert_equal "Speaker 2", @speaker.display_name
    assert_no_evidence
  end

  test "delete identity while retired cannot be undone by recovery" do
    retire_last_line!
    @voice.delete_identity!
    @speaker.restore!

    assert_nil @speaker.reload.field_voice_id
    assert_nil @speaker.naming_source
    assert_nil @speaker.named_by_id
    assert_nil @speaker.named_at
    assert_equal "Speaker 2", @speaker.display_name
    assert_no_evidence
  end

  test "merge moves retired links and subsequent identity revocation still reaches them" do
    retire_last_line!
    target = @account.field_voices.create!(name: "Kept identity")
    @voice.merge_into!(target)
    assert_equal target.id, @speaker.reload.field_voice_id
    assert_equal "human", @speaker.naming_source
    assert_equal @user.id, @speaker.named_by_id
    assert @speaker.retired?
    assert_no_evidence
    target.delete_identity!
    @speaker.restore!
    assert_nil @speaker.reload.field_voice_id
    assert_nil @speaker.naming_source
    assert_no_evidence
  end

  test "Forget then restore preserves naming but never recreates biometric evidence" do
    retire_last_line!
    @voice.forget!
    @recording.restore_speaker_line!(@speaker, line: current_line[:locator],
      was: current_line[:text], revision: @recording.reload.transcript_revision)

    assert_equal @voice.id, @speaker.reload.field_voice_id
    assert_equal "human", @speaker.naming_source
    assert_nil FieldVoiceprints::Learning.snapshot_for(@speaker)
    assert_not @voice.reload.remember?
    assert_no_evidence
  end

  private

  def current_line = @recording.reload.transcript_lines.first

  def retire_last_line!
    @recording.reload.reassign_line!({ first: 2, last: 2 }, to: @other, was: "reply",
      revision: @recording.transcript_revision)
    @speaker.reload
  end

  def assert_no_evidence
    assert_empty @speaker.voice_samples.reload
    fields = %w[probe_embedding probe_profile auto_named_confidence
      suggested_voice_id suggested_name suggestion_quote suggestion_quote_ms suggestion_source suggested_at suggestion_generation
      recognised_voice_id recognition_confidence recognition_print_generation recognition_decision_generation recognition_cohort recognition_checked
      sample_confirmed_digest sample_confirmed_by_id sample_confirmed_at sample_learning_status sample_learning_error]
    fields.each { |field| assert_nil @speaker.public_send(field), field }
    assert_nil @speaker.clip_start_ms if @speaker.retired?
    assert_nil @speaker.clip_end_ms if @speaker.retired?
  end

end
