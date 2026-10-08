require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceprintsTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker, @other = @recording.speakers.to_a
    @voice = @account.field_voices.create!(name: "Tomás")
    @speaker.name_as!(@voice, by: @user)
  end

  def fake_cut
    FieldVoiceprints::Sample.stub(:cut, ->(_recording, _segments, &block) {
      Tempfile.create([ "s", ".wav" ]) { |file| block.call(file.path) }
    }) { yield }
  end

  test "both gates must be open, and the house gate needs a stated backup retention and pyannote" do
    assert_not FieldVoiceprints.enabled_for?(@account)
    with_recognition(@account) { assert FieldVoiceprints.enabled_for?(@account) }

    with_recognition(@account) do
      ENV["SOULSHOUSE_BACKUP_RETENTION_DAYS"] = ""
      assert_not FieldVoiceprints.house_enabled?, "no stated retention, no recognition"
    end
    with_recognition(@account) do
      @account.update!(recognise_voices: false)
      assert_not FieldVoiceprints.enabled_for?(@account)
    end
  end

  test "the sample is clean turns only, at least 8 s, at most 30 s" do
    segments = FieldVoiceprints::Sample.segments_for(@speaker)
    assert_equal [ [ 0, 12_000 ], [ 17_000, 22_000 ] ], segments, "the first two words are one turn"

    error = assert_raises(FieldVoiceprints::Sample::Refused) { FieldVoiceprints::Sample.segments_for(@other) }
    assert_match "isn't enough clear speech", error.message
  end

  test "fewer speakers than expected means no sample" do
    @recording.update_columns(expected_speakers: 3)
    error = assert_raises(FieldVoiceprints::Sample::Refused) { FieldVoiceprints::Sample.segments_for(@speaker.reload) }
    assert_match "Fewer voices", error.message
  end

  test "the sample is really cut by ffmpeg" do
    recording = ready_recording(account: @account, user: @user)
    FieldVoiceprints::Sample.cut(recording, [ [ 0, 400 ], [ 500, 900 ] ]) do |path|
      assert_operator File.size(path), :>, 1000
      assert_operator FieldRecording::Probe.duration_ms(path), :<=, 1_000
    end
  end

  test "nothing biometric happens while a gate is shut: no enrolment, no send, no identify" do
    client = FakePyannote.new
    assert_raises(FieldVoiceprints::Enrolments::Refused) { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) }
    assert_nil FieldVoiceprints::Identification.dispatch!(@recording, client:)
    assert_empty client.voiceprint_calls + client.identify_calls
    assert_equal 0, FieldVoiceEnrolment.count
  end

  test "remembering is three explicit steps and stores a print with a new generation" do
    client = FakePyannote.new
    with_recognition(@account) do
      enrolment = fake_cut { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) }
      assert enrolment.sample.attached?
      assert_empty client.voiceprint_calls, "nothing is sent before 'use it'"

      FieldVoiceprints::Enrolments.dispatch!(enrolment, client:)
      assert_equal 1, client.voiceprint_calls.size
      assert FieldVoiceprints::Enrolments.write_back!(enrolment.id, "PRINT")
    end

    print = @voice.reload.voiceprint
    assert_equal "PRINT", print.print
    assert_equal @voice.print_generation, print.generation
    assert_equal @user, print.consented_by
    assert_equal 0, FieldVoiceEnrolment.count
  end

  test "forget is always allowed, with no gate, print or consent, and moves the generation on" do
    store_print!(@voice)
    before = @voice.reload.print_generation
    @other.update!(recognised_voice: @voice, recognition_confidence: 80, recognition_print_generation: before)

    @voice.forget! # gates are shut here
    assert_nil FieldVoiceprint.find_by(field_voice: @voice)
    assert_operator @voice.reload.print_generation, :>, before
    assert_nil @other.reload.recognised_voice_id
    assert_equal "Tomás", @speaker.reload.display_name, "names people gave stay"

    assert_nothing_raised { accounts(:another_team).field_voices.create!(name: "No print").forget! }
  end

  test "forget → re-enrol → a result started before the forget can't be stored" do
    client = FakePyannote.new
    with_recognition(@account) do
      old = fake_cut { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) }
      FieldVoiceprints::Enrolments.dispatch!(old, client:)
      @voice.forget!
      fresh = fake_cut { FieldVoiceprints::Enrolments.start!(@speaker.reload, by: @user) }

      assert_not FieldVoiceprints::Enrolments.write_back!(old.id, "OLD"), "the forgotten enrolment is gone"
      FieldVoiceprints::Enrolments.dispatch!(fresh, client:)
      assert FieldVoiceprints::Enrolments.write_back!(fresh.id, "NEW")
    end
    assert_equal "NEW", @voice.reload.voiceprint.print
  end

  test "a write-back after a gate shut, or after the generation moved, is thrown away" do
    client = FakePyannote.new
    enrolment = nil
    with_recognition(@account) do
      enrolment = fake_cut { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) }
      FieldVoiceprints::Enrolments.dispatch!(enrolment, client:)
    end
    assert_not FieldVoiceprints::Enrolments.write_back!(enrolment.id, "PRINT"), "gate shut mid-flight"
    assert_nil @voice.reload.voiceprint

    with_recognition(@account) do
      second = fake_cut { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) }
      FieldVoiceprints::Enrolments.dispatch!(second, client:)
      @voice.update_columns(print_generation: @voice.print_generation + 1) # someone else's change landed
      assert_not FieldVoiceprints::Enrolments.write_back!(second.id, "PRINT")
    end
    assert_nil @voice.reload.voiceprint
  end

  test "identify sends opaque labels and only current prints, then recognises an unnamed speaker" do
    store_print!(@voice, print: "TOMAS")
    stale = @account.field_voices.create!(name: "Stale")
    store_print!(stale).update_columns(generation: 0) # no longer current
    @speaker.unname!
    client = FakePyannote.new

    identification = with_recognition(@account) { FieldVoiceprints::Identification.dispatch!(@recording, client:) }
    sent = client.identify_calls.first[:voiceprints]
    assert_equal [ "TOMAS" ], sent.map { |v| v[:voiceprint] }
    assert_no_match "Tomás", sent.to_json
    label = sent.first[:label]

    output = {
      "identification" => [ { "start" => 0.0, "end" => 12.5, "match" => label, "diarizationSpeaker" => "SPEAKER_00" },
                            { "start" => 16.5, "end" => 23.0, "match" => label, "diarizationSpeaker" => "SPEAKER_00" } ],
      "voiceprints" => [ { "speaker" => "SPEAKER_00", "confidence" => { label => 84 } } ]
    }
    with_recognition(@account) { assert FieldVoiceprints::Identification.apply!(identification, output) }

    @speaker.reload
    assert_equal @voice, @speaker.recognised_voice
    assert_equal 84, @speaker.recognition_confidence
    assert_equal "Speaker 1", @speaker.display_name, "a recognition is a guess, not a name"
    assert_nil @other.reload.recognised_voice_id
  end

  test "a late identify result for a forgotten, re-enrolled voice is ignored" do
    store_print!(@voice)
    @speaker.unname!
    client = FakePyannote.new
    identification = with_recognition(@account) { FieldVoiceprints::Identification.dispatch!(@recording, client:) }
    label = client.identify_calls.first[:voiceprints].first[:label]

    @voice.forget!
    store_print!(@voice) # re-enrolled: a new print, a newer generation

    output = { "identification" => [ { "start" => 0.0, "end" => 23.0, "match" => label, "diarizationSpeaker" => "S" } ] }
    with_recognition(@account) { FieldVoiceprints::Identification.apply!(identification, output) }
    assert_nil @speaker.reload.recognised_voice_id
  end

  test "named speakers are never touched by recognition" do
    store_print!(@voice)
    client = FakePyannote.new
    identification = with_recognition(@account) { FieldVoiceprints::Identification.dispatch!(@recording, client:) }
    label = client.identify_calls.first[:voiceprints].first[:label]
    output = { "identification" => [ { "start" => 0.0, "end" => 23.0, "match" => label, "diarizationSpeaker" => "S" } ] }
    with_recognition(@account) { FieldVoiceprints::Identification.apply!(identification, output) }
    assert_nil @speaker.reload.recognised_voice_id
    assert_equal @voice, @speaker.field_voice
  end

  test "matching: 70% of clean speech in one voice's segments, none in another's; crosstalk left out" do
    words = FieldRecording::Transcript.compact(scribe_words(
      [ "speaker_0", 0.0, 4.0, "a" ], [ "speaker_0", 4.0, 8.0, "b" ], [ "speaker_0", 8.0, 10.0, "c" ]
    ))
    valid = { "A" => [ 1, 1 ], "B" => [ 2, 1 ] }
    seg = ->(s, e, m) { { "start" => s, "end" => e, "match" => m, "diarizationSpeaker" => "X" } }

    assert_equal 1, FieldVoiceprints::Matching.recognitions(words, { "identification" => [ seg.(0, 8, "A") ] }, valid)
      .dig("speaker_0", :voice_id), "8 of 10 s"
    assert_empty FieldVoiceprints::Matching.recognitions(words, { "identification" => [ seg.(0, 6, "A") ] }, valid),
      "6 of 10 s is not enough"
    assert_empty FieldVoiceprints::Matching.recognitions(words,
      { "identification" => [ seg.(0, 8, "A"), seg.(8, 10, "B") ] }, valid), "a conflicting voice means no guess"
    assert_empty FieldVoiceprints::Matching.recognitions(words, { "identification" => [ seg.(0, 10, "Z") ] }, valid),
      "a label no longer valid counts for nothing"
  end

  test "confirming a current recognition names the speaker and builds nothing; a stale one is refused" do
    store_print!(@voice)
    @speaker.unname!
    @speaker.update!(recognised_voice: @voice, recognition_confidence: 80, recognition_print_generation: @voice.reload.print_generation)

    with_recognition(@account) { assert @speaker.confirm_recognition!(by: @user) }
    assert_equal "confirmed_recognition", @speaker.reload.naming_source
    assert_equal 1, FieldVoiceprint.count, "confirming never builds a print"

    @other.update!(recognised_voice: @voice, recognition_confidence: 80, recognition_print_generation: @voice.print_generation - 1)
    with_recognition(@account) { assert_not @other.confirm_recognition!(by: @user) }
    assert_nil @other.reload.recognised_voice_id
    assert_nil @other.field_voice
  end

  test "confirming with a gate shut is refused" do
    store_print!(@voice)
    @speaker.unname!
    @speaker.update!(recognised_voice: @voice, recognition_print_generation: @voice.reload.print_generation)
    assert_not @speaker.confirm_recognition!(by: @user)
  end

  test "switching the gate on builds nothing for voices named before" do
    with_recognition(@account) { assert_equal 0, FieldVoiceprint.count + FieldVoiceEnrolment.count }
  end

  test "prints refuse to be serialised" do
    print = store_print!(@voice)
    assert_raises(NotImplementedError) { print.as_json }
    assert_no_match print.print, print.inspect
  end

  test "the restore reset clears every print, enrolment and guess, keeps names, and moves every generation" do
    store_print!(@voice)
    @other.update!(recognised_voice: @voice, recognition_print_generation: 1)
    before = @voice.reload.print_generation

    FieldVoiceprints.reset_all!
    assert_equal 0, FieldVoiceprint.count
    assert_nil @other.reload.recognised_voice_id
    assert_operator @voice.reload.print_generation, :>, before
    assert_equal "Tomás", @speaker.reload.display_name
  end

  test "deleting a voice forgets its print and returns its speakers to 'Speaker N'" do
    store_print!(@voice)
    @voice.delete_identity!
    assert_nil FieldVoiceprint.find_by(field_voice_id: @voice.id)
    assert_equal "Speaker 1", @speaker.reload.display_name
    assert @voice.reload.discarded?
    assert_match "Speaker 1:", @recording.reload.transcript_text
  end

end
