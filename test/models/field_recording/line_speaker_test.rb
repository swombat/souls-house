require "test_helper"
require "support/field_recording_helpers"

class FieldRecording::LineSpeakerTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    # Lines: "first long" (speaker_0), "reply" (speaker_1), "again" (speaker_0).
    @recording = long_ready_recording(account: @account, user: @user)
  end

  def spoken(recording) = recording.transcript_words.reject { |word| word["k"] == "s" }.map { |word| word.values_at("t", "spk") }
  def speaker(label) = @recording.speakers.find_by(label:)

  test "a line moves to an existing speaker; words and timings stay, talk time follows" do
    before = @recording.transcript_words.map { |word| word.except("spk") }
    talk = speaker("speaker_0").talk_ms

    @recording.reassign_line!({ first: 3, last: 3 }, to: speaker("speaker_1"), was: "again",
      revision: @recording.transcript_revision)

    @recording.reload
    assert_equal [ %w[first speaker_0], %w[long speaker_0], %w[reply speaker_1], %w[again speaker_1] ], spoken(@recording)
    assert_equal before, @recording.transcript_words.map { |word| word.except("spk") }
    assert_equal talk - 5000, speaker("speaker_0").talk_ms
    assert_equal 6000, speaker("speaker_1").talk_ms
    assert_includes @recording.transcript_text, "[00:17] Speaker 2: again"
  end

  test "spacing inside a line moves with it" do
    @recording.reassign_line!({ first: 0, last: 1 }, to: speaker("speaker_1"), was: "first long",
      revision: @recording.transcript_revision)

    entries = @recording.reload.transcript_words
    assert_equal %w[speaker_1 speaker_1 speaker_1], entries[0..2].map { |word| word["spk"] }
    assert_equal "s", entries[1]["k"]
  end

  test "someone new is an unnamed speaker after the others, and nobody is renumbered" do
    new_speaker = @recording.reassign_line!({ first: 2, last: 2 }, to: :new, was: "reply",
      revision: @recording.transcript_revision)

    @recording.reload
    assert_equal "speaker_2", new_speaker.label
    assert_equal [ [ "speaker_0", 0 ], [ "speaker_2", 2 ] ], @recording.speakers.in_order.map { |s| [ s.label, s.position ] }
    assert new_speaker.reload.unnamed?
    assert_equal 1000, new_speaker.talk_ms
    assert_includes @recording.transcript_text, "Speaker 3: reply"
  end

  test "a speaker left with no lines stays while a sent voice sample is out" do
    voice = @account.field_voices.create!(name: "Tomás")
    FieldVoiceEnrolment.create!(account: @account, field_voice: voice, field_recording_speaker: speaker("speaker_1"),
      start_generation: 0, sample_ms: 1000, consent_text_version: FieldVoiceprints::CONSENT_TEXT_VERSION,
      consented_by: @user, expires_at: 10.minutes.from_now, status: "dispatched", vendor_job_id: "job_1")

    @recording.reassign_line!({ first: 2, last: 2 }, to: speaker("speaker_0"), was: "reply",
      revision: @recording.transcript_revision)

    kept = @recording.reload.speakers.find_by(label: "speaker_1")
    assert kept
    assert_equal 0, kept.talk_ms
    assert_nil kept.clip_start_ms
  end

  def cut_stub(during = nil)
    ->(_recording, _segments, &block) { during&.call; Tempfile.create([ "s", ".wav" ]) { |f| block.call(f.path) } }
  end

  test "moving a line while a voice sample is being cut refuses the sample" do
    anna = speaker("speaker_0")
    anna.name_as!(@account.field_voices.create!(name: "Anna"), by: @user)
    move = -> { @recording.reload.reassign_line!({ first: 3, last: 3 }, to: speaker("speaker_1"), was: "again",
      revision: @recording.transcript_revision) }

    with_recognition(@account) do
      FieldVoiceprints::Sample.stub(:cut, cut_stub(move)) do
        assert_raises(FieldVoiceprints::Enrolments::Refused) { FieldVoiceprints::Enrolments.start!(anna.reload, by: @user) }
      end
    end
    assert_equal 0, FieldVoiceEnrolment.where(field_recording_speaker: anna).count
  end

  test "moving a line throws away a waiting preview, and a sent sample's print is refused" do
    anna = speaker("speaker_0")
    voice = @account.field_voices.create!(name: "Anna")
    anna.name_as!(voice, by: @user)

    with_recognition(@account) do
      preview = FieldVoiceprints::Sample.stub(:cut, cut_stub) { FieldVoiceprints::Enrolments.start!(anna.reload, by: @user) }
      @recording.reload.reassign_line!({ first: 3, last: 3 }, to: speaker("speaker_1"), was: "again",
        revision: @recording.transcript_revision)
      assert_not FieldVoiceEnrolment.exists?(preview.id)

      sent = FieldVoiceprints::Sample.stub(:cut, cut_stub) { FieldVoiceprints::Enrolments.start!(anna.reload, by: @user) }
      FieldVoiceprints::Enrolments.dispatch!(sent, client: FakePyannote.new)
      @recording.reload.reassign_line!({ first: 2, last: 2 }, to: anna.reload, was: "reply",
        revision: @recording.transcript_revision)
      assert_equal false, FieldVoiceprints::Enrolments.write_back!(sent.id, "PRINT")
      assert_nil FieldVoiceprint.find_by(field_voice: voice)
    end
  end

  test "a move clears suggestions on the speakers it touched, and only those" do
    recording = queued_recording(account: @account, user: @user)
    recording.accept_transcript!(recording.claim_dispatch!, scribe_transcription(words: scribe_words(
      [ "speaker_0", 0.0, 1.0, "one" ], [ "speaker_1", 3.0, 4.0, "two" ], [ "speaker_2", 6.0, 7.0, "three" ]
    )))
    recording.reload
    recording.speakers.each { |s| s.update!(suggested_name: "Name #{s.label}", suggestion_quote: "x", suggestion_source: "utility") }

    recording.reassign_line!({ first: 1, last: 1 }, to: recording.speakers.find_by(label: "speaker_0"), was: "two",
      revision: recording.transcript_revision)

    left = recording.reload.speakers.index_by(&:label)
    assert_equal %w[speaker_0 speaker_2], left.keys.sort
    assert_nil left["speaker_0"].suggested_name
    assert_equal 1, left["speaker_0"].decision_generation
    assert_equal "Name speaker_2", left["speaker_2"].suggested_name
    assert_equal 0, left["speaker_2"].decision_generation
  end

  test "an old revision, a line that reads differently, or a speaker that went changes nothing" do
    seen = @recording.transcript_revision
    gone = speaker("speaker_1")
    other = long_ready_recording(account: @account, user: @user).speakers.first

    assert_raises(FieldRecording::LineCorrection::Stale) do
      @recording.reassign_line!({ first: 2, last: 2 }, to: :new, was: "reply", revision: "0000000000000000")
    end
    assert_raises(FieldRecording::LineCorrection::Stale) do
      @recording.reassign_line!({ first: 2, last: 2 }, to: :new, was: "again", revision: seen)
    end
    assert_raises(FieldRecording::LineCorrection::Stale) do
      @recording.reassign_line!({ first: 2, last: 9 }, to: :new, was: "reply", revision: seen)
    end
    assert_raises(FieldRecording::LineCorrection::Stale) do
      @recording.reassign_line!({ first: 3, last: 3 }, to: other, was: "again", revision: seen)
    end
    gone.destroy!
    assert_raises(FieldRecording::LineCorrection::Stale) do
      @recording.reassign_line!({ first: 3, last: 3 }, to: gone, was: "again", revision: seen)
    end
    assert_equal seen, @recording.reload.transcript_revision
  end

  test "a supplied transcript's turn moves to another speaker or someone new" do
    recording = FieldRecording::Upload.claim!(
      account: @account, user: @user, signed_id: pinned_blob(account: @account, user: @user).signed_id,
      attributes: { title: "Archive" },
      supplied_turns: FieldRecording::SuppliedTranscript.parse("Anna: Hi Dad.\nDaniel: Hello.\nAnna: Bye.")
    )
    daniel = recording.speakers.find_by!(label: "Daniel")

    recording.reassign_line!({ index: 2 }, to: daniel, was: "Bye.", revision: recording.transcript_revision)
    assert_equal %w[Anna Daniel Daniel], recording.reload.transcript_turns.map { |turn| turn["spk"] }
    assert_equal %w[Anna Daniel], recording.speakers.in_order.map(&:label)

    recording.reassign_line!({ index: 0 }, to: :new, was: "Hi Dad.", revision: recording.transcript_revision)
    recording.reload
    assert_equal %w[Daniel speaker_0], recording.speakers.in_order.map(&:label)
    assert_match(/Speaker 3: Hi Dad\./, recording.transcript_text)
  end

end
