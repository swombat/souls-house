require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceprintsTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

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

  # A recording nobody has touched: identify may guess at its speakers.
  def untouched_recording = long_ready_recording(account: @account, user: @user)

  def identify!(recording, client = FakePyannote.new)
    identification = with_recognition(@account) { FieldVoiceprints::Identification.dispatch!(recording, client:) }
    [ identification, client.identify_calls.last&.dig(:voiceprints, 0, :label), client ]
  end

  def segment(from, to, label, diar: "SPEAKER_00") = { "start" => from, "end" => to, "match" => label, "diarizationSpeaker" => diar }

  test "identify sends opaque labels and only current prints, then recognises an untouched speaker" do
    store_print!(@voice, print: "TOMAS")
    stale = @account.field_voices.create!(name: "Stale")
    store_print!(stale).update_columns(generation: 0) # no longer current
    fresh = untouched_recording
    identification, label, client = identify!(fresh)

    sent = client.identify_calls.first[:voiceprints]
    assert_equal [ "TOMAS" ], sent.map { |v| v[:voiceprint] }
    assert_no_match "Tomás", sent.to_json

    output = { "identification" => [ segment(0.0, 12.5, label), segment(16.5, 23.0, label) ],
               "voiceprints" => [ { "speaker" => "SPEAKER_00", "confidence" => { label => 84 } } ] }
    with_recognition(@account) { assert FieldVoiceprints::Identification.apply!(identification, output) }

    speaker = fresh.speakers.first.reload
    assert_equal @voice, speaker.recognised_voice
    assert_equal 84, speaker.recognition_confidence
    assert_equal 0, speaker.recognition_decision_generation
    assert_equal "Speaker 1", speaker.display_name, "a recognition is a guess, not a name"
  end

  test "a late identify result for a forgotten, re-enrolled voice is ignored" do
    store_print!(@voice)
    fresh = untouched_recording
    identification, label = identify!(fresh)
    @voice.forget!
    store_print!(@voice)

    output = { "identification" => [ segment(0.0, 23.0, label) ] }
    with_recognition(@account) { FieldVoiceprints::Identification.apply!(identification, output) }
    assert_nil fresh.speakers.first.reload.recognised_voice_id
  end

  test "a late identify result honours what a person decided meanwhile: named, then un-named" do
    store_print!(@voice)
    fresh = untouched_recording
    identification, label = identify!(fresh)
    speaker = fresh.speakers.first
    speaker.name_as!(@account.field_voices.create!(name: "Someone"), by: @user)
    speaker.reload.unname!

    output = { "identification" => [ segment(0.0, 23.0, label) ] }
    with_recognition(@account) { FieldVoiceprints::Identification.apply!(identification, output) }
    assert_nil speaker.reload.recognised_voice_id, "a correction back to 'Speaker 1' is respected"
  end

  test "speakers anyone has decided about are never guessed at, named or not" do
    store_print!(@voice)
    identification, label = identify!(@recording) # @speaker is named in setup
    output = { "identification" => [ segment(0.0, 23.0, label) ] }
    with_recognition(@account) { FieldVoiceprints::Identification.apply!(identification, output) }
    assert_nil @speaker.reload.recognised_voice_id
    assert_equal @voice, @speaker.field_voice
  end

  test "matching works on intervals: partial words, conflicts and nested overlaps" do
    one_word = [ { "s" => 0, "e" => 1000, "t" => "x", "k" => "w", "spk" => "a" } ]
    valid = { "A" => [ 1, 1 ], "B" => [ 2, 1 ] }
    out = ->(*segs) { { "identification" => segs } }

    assert_empty FieldVoiceprints::Matching.recognitions(one_word, out.(segment(0.49, 0.51, "A")), valid),
      "2% real coverage is not a recognition"
    assert_empty FieldVoiceprints::Matching.recognitions(one_word, out.(segment(0, 0.6, "A"), segment(0.6, 1.0, "B")), valid),
      "40% conflicting time means no guess"
    assert_equal [ [ 1, 2 ], [ 3, 4 ] ], FieldVoiceprints::Matching.crowded([ [ 0, 10 ], [ 1, 2 ], [ 3, 4 ] ]),
      "every nested overlap counts, not just adjacent ones"
    assert_equal 1, FieldVoiceprints::Matching.recognitions(one_word, out.(segment(0, 0.8, "A")), valid).dig("a", :voice_id)
    assert_empty FieldVoiceprints::Matching.recognitions(one_word, out.(segment(0, 0.6, "A")), valid), "60% is not enough"
    assert_empty FieldVoiceprints::Matching.recognitions(one_word, out.(segment(0, 1.0, "Z")), valid),
      "a label no longer valid counts for nothing"
  end

  test "matching leaves real crosstalk out of the count" do
    words = [ { "s" => 0, "e" => 10_000, "t" => "long", "k" => "w", "spk" => "a" },
              { "s" => 2_000, "e" => 5_000, "t" => "over", "k" => "w", "spk" => "b" } ]
    valid = { "A" => [ 1, 1 ] }
    # A covers 0–2 s and 5–10 s: all of a's speech once the 2–5 s crosstalk is removed.
    found = FieldVoiceprints::Matching.recognitions(words, { "identification" => [ segment(0, 2, "A"), segment(5, 10, "A") ] }, valid)
    assert_equal 1, found.dig("a", :voice_id)
    assert_nil found["b"], "b only ever spoke over someone"
  end

  test "malformed identify output is handled, not raised" do
    words = [ { "s" => 0, "e" => 1000, "t" => "x", "k" => "w", "spk" => "a" } ]
    [ nil, [], { "identification" => "junk" }, { "identification" => [ { "start" => "x" }, nil, 3 ] } ].each do |output|
      assert_equal({}, FieldVoiceprints::Matching.recognitions(words, output, { "A" => [ 1, 1 ] }))
    end
  end

  def guess!(speaker, generation: @voice.reload.print_generation)
    speaker.update!(recognised_voice: @voice, recognition_confidence: 80, recognition_print_generation: generation,
      recognition_decision_generation: speaker.decision_generation)
    speaker.reload.recognition_token
  end

  test "confirming the guess the chip showed names the speaker and builds nothing" do
    store_print!(@voice)
    speaker = untouched_recording.speakers.first
    token = guess!(speaker)

    with_recognition(@account) { assert speaker.confirm_recognition!(by: @user, shown: token) }
    assert_equal "confirmed_recognition", speaker.reload.naming_source
    assert_equal 1, FieldVoiceprint.count, "confirming never builds a print"
  end

  test "a stale chip can't confirm or dismiss: different guess, decision since, print moved, gate shut" do
    store_print!(@voice)
    speaker = untouched_recording.speakers.first
    old_token = guess!(speaker)
    other = @account.field_voices.create!(name: "Priya")
    store_print!(other)
    speaker.update!(recognised_voice: other, recognition_print_generation: other.reload.print_generation)

    with_recognition(@account) do
      assert_not speaker.confirm_recognition!(by: @user, shown: old_token), "the chip showed Tomás, the guess is now Priya"
      assert_not speaker.dismiss_recognition!(shown: old_token)
    end
    assert_equal other, speaker.reload.recognised_voice, "a refused stale request changes nothing"

    token = guess!(speaker, generation: @voice.reload.print_generation - 1) # print replaced since
    with_recognition(@account) { assert_not speaker.confirm_recognition!(by: @user, shown: token) }
    assert_nil speaker.reload.field_voice

    token = guess!(speaker)
    assert_not speaker.confirm_recognition!(by: @user, shown: token), "gate shut"
    assert speaker.dismiss_recognition!(shown: token), "dismissing a guess works with the gate shut"
    assert_nil speaker.reload.recognised_voice_id
  end

  test "a forget during the cut leaves no preview behind" do
    with_recognition(@account) do
      FieldVoiceprints::Sample.stub(:cut, ->(_r, _s, &block) {
        @voice.forget! # lands between the snapshot and the store
        Tempfile.create([ "s", ".wav" ]) { |f| block.call(f.path) }
      }) do
        assert_raises(FieldVoiceprints::Enrolments::Refused) { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) }
      end
    end
    assert_equal 0, FieldVoiceEnrolment.count
  end

  test "un-naming, discarding or shutting the gate between preview and send stops the send" do
    client = FakePyannote.new
    with_recognition(@account) do
      enrolment = fake_cut { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) }
      @speaker.reload.unname!
      @speaker.reload.name_as!(@voice, by: @user) # same voice again, but a new decision
      assert_raises(FieldVoiceprints::Enrolments::Refused) { FieldVoiceprints::Enrolments.dispatch!(enrolment, client:) }

      enrolment = fake_cut { FieldVoiceprints::Enrolments.start!(@speaker.reload, by: @user) }
      @recording.discard_and_settle!
      assert_raises(FieldVoiceprints::Enrolments::Refused) { FieldVoiceprints::Enrolments.dispatch!(enrolment, client:) }
    end
    assert_empty client.voiceprint_calls
  end

  test "an uncertain send ends the enrolment for good; the same consent is never sent twice" do
    failing = Object.new
    def failing.voiceprint(url:) = raise(PyannoteClient::TransientError, "pyannote transport failure (Net::ReadTimeout)")
    with_recognition(@account) do
      enrolment = fake_cut { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) }
      assert_raises(FieldVoiceprints::Enrolments::Uncertain) { FieldVoiceprints::Enrolments.dispatch!(enrolment, client: failing) }
      assert_not FieldVoiceEnrolment.exists?(enrolment.id)
      assert_raises(FieldVoiceprints::Enrolments::Refused) { FieldVoiceprints::Enrolments.dispatch!(enrolment, client: FakePyannote.new) }
    end
  end

  test "expired previews are swept away with their samples" do
    enrolment = with_recognition(@account) { fake_cut { FieldVoiceprints::Enrolments.start!(@speaker, by: @user) } }
    blob = enrolment.sample.blob
    travel FieldVoiceprints::ENROLMENT_TTL + 1.minute do
      perform_enqueued_jobs { FieldVoices::EnrolmentSweepJob.perform_now }
    end
    assert_not FieldVoiceEnrolment.exists?(enrolment.id)
    assert_not ActiveStorage::Blob.exists?(blob.id)
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
    @other.update!(recognised_voice: @voice, recognition_print_generation: 1, recognition_decision_generation: 0)
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
