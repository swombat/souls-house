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

  def fake_cut(&)
    FieldVoiceprints::Sample.stub(:cut, ->(_recording, _segments, &block) {
      Tempfile.create([ "s", ".wav" ]) { |file| block.call(file.path) }
    }, &)
  end

  def embeddings(vector = voice_vector(1)) = FakeVoiceEmbeddings.new({ default: vector })

  # A client whose embed runs `during` first: something a person does while
  # the audio work is outside every lock.
  def embeddings_while(vector = voice_vector(1), &during)
    client = Object.new
    client.define_singleton_method(:embed) do |_wav|
      during.call
      FieldVoiceprints::VoiceEmbeddings::Result.new(embedding: vector, profile: "ecapa-test")
    end
    client
  end

  def snapshot(speaker = @speaker) = FieldVoiceprints::Learning.snapshot_for(speaker.reload)

  test "both gates must be open, and the house gate is the voice service being configured" do
    assert @account.recognise_voices?, "recognition is on by default"
    assert_not FieldVoiceprints.house_enabled?, "no voice service is configured here"
    assert_not FieldVoiceprints.enabled_for?(@account)
    with_recognition(@account) { assert FieldVoiceprints.enabled_for?(@account) }
    with_recognition(@account) do
      @account.update!(recognise_voices: false)
      assert_not FieldVoiceprints.enabled_for?(@account)
    end

    with_recognition(@account) do
      ENV["VOICE_EMBEDDING_TOKEN"] = "short"
      assert_not FieldVoiceprints.house_enabled?, "a service without a real token is not configured"
    end
  end

  test "the sample is clean turns only, at least 4 s, at most 60 s" do
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

  test "nothing biometric happens while a gate is shut: nothing learned, nothing embedded, no guess" do
    client = embeddings
    store_print!(@voice)
    assert_nil snapshot, "a naming with the gate shut queues no learning"
    assert_nil FieldVoiceprints::Identification.run!(untouched_recording, client:)
    assert_empty client.calls
    assert_equal 0, FieldVoiceSample.count
  end

  test "forget is always allowed, with no gate or print, moves the generations on and stops learning" do
    store_print!(@voice)
    before = @voice.reload.print_generation
    learning = @voice.learning_generation
    @other.update!(recognised_voice: @voice, recognition_confidence: 80, recognition_print_generation: before)

    @voice.forget! # gates are shut here
    assert_nil FieldVoiceprint.find_by(field_voice: @voice)
    assert_operator @voice.reload.print_generation, :>, before
    assert_operator @voice.learning_generation, :>, learning
    assert_not @voice.remember?
    assert_nil @other.reload.recognised_voice_id
    assert_equal "Tomás", @speaker.reload.display_name, "names people gave stay"

    assert_nothing_raised { accounts(:another_team).field_voices.create!(name: "No print").forget! }
  end

  test "forget → remember again → a sample taken before the forget can't be stored" do
    with_recognition(@account) do
      old = snapshot
      @voice.forget!
      @voice.reload.remember_again!

      assert_equal :stale, fake_cut { FieldVoiceprints::Learning.learn!(old, client: embeddings) }
      assert_equal :learned, fake_cut { FieldVoiceprints::Learning.learn!(snapshot, client: embeddings) }
    end
    assert_equal 1, @voice.samples.count
  end

  test "a sample learned after a gate shut, or after the learning generation moved, is thrown away" do
    client = embeddings
    taken = with_recognition(@account) { snapshot }
    assert_equal :stale, fake_cut { FieldVoiceprints::Learning.learn!(taken, client:) }, "gate shut mid-flight"

    with_recognition(@account) do
      taken = snapshot
      @voice.update_columns(learning_generation: @voice.reload.learning_generation + 1) # someone else's change landed
      assert_equal :stale, fake_cut { FieldVoiceprints::Learning.learn!(taken, client:) }
    end
    assert_empty client.calls
    assert_nil @voice.reload.voiceprint
    assert_equal 0, FieldVoiceSample.count
  end

  # A recording nobody has touched: identification may guess at its speakers.
  def untouched_recording = long_ready_recording(account: @account, user: @user)

  def identify!(recording, client = embeddings)
    with_recognition(@account) { fake_cut { FieldVoiceprints::Identification.run!(recording, client:) } }
  end

  test "identification matches only current, active prints, then guesses at an untouched speaker" do
    store_print!(@voice, vector: voice_vector(1))
    stale = @account.field_voices.create!(name: "Stale")
    store_print!(stale, vector: voice_vector(1)).update_columns(generation: 0) # no longer current
    unchecked = @account.field_voices.create!(name: "Unchecked")
    store_print!(unchecked, vector: voice_vector(1), active: false) # not validated yet
    fresh = untouched_recording

    assert_equal 1, identify!(fresh), "the matching stale and unchecked prints would have tied it"

    speaker = fresh.speakers.first.reload
    assert_equal @voice, speaker.recognised_voice
    assert_equal 100, speaker.recognition_confidence
    assert_equal 0, speaker.recognition_decision_generation
    assert speaker.probe_embedding.present?, "the probe is kept for matching again"
    assert_equal "Speaker 1", speaker.display_name, "a recognition is a guess, not a name"
    assert_nil fresh.speakers.last.reload.recognised_voice_id, "too little clean speech to embed"
  end

  test "a late match for a forgotten, re-remembered voice is ignored" do
    store_print!(@voice)
    fresh = untouched_recording
    client = embeddings_while(voice_vector(@voice.id % 100)) do
      @voice.forget!
      store_print!(@voice.reload)
    end
    identify!(fresh, client)
    assert_nil fresh.speakers.first.reload.recognised_voice_id
  end

  test "a late match honours what a person decided meanwhile: named, then un-named" do
    store_print!(@voice)
    fresh = untouched_recording
    speaker = fresh.speakers.first
    client = embeddings_while(voice_vector(@voice.id % 100)) do
      speaker.name_as!(@account.field_voices.create!(name: "Someone"), by: @user)
      speaker.reload.unname!
    end
    identify!(fresh, client)
    assert_nil speaker.reload.recognised_voice_id, "a correction back to 'Speaker 1' is respected"
  end

  test "speakers anyone has decided about are never guessed at, named or not" do
    store_print!(@voice)
    client = embeddings(voice_vector(@voice.id % 100))
    identify!(@recording, client) # @speaker is named in setup
    assert_nil @speaker.reload.recognised_voice_id
    assert_equal @voice, @speaker.field_voice
    assert_empty client.calls, "nobody undecided had enough speech to embed"
  end

  def guess!(speaker, generation: @voice.reload.print_generation)
    speaker.update!(recognised_voice: @voice, recognition_confidence: 80, recognition_print_generation: generation,
      recognition_decision_generation: speaker.decision_generation)
    speaker.reload.recognition_token
  end

  test "confirming the guess the chip showed names the speaker and learns from it" do
    store_print!(@voice)
    speaker = untouched_recording.speakers.first
    token = guess!(speaker)

    with_recognition(@account) do
      assert_enqueued_with(job: FieldVoices::LearnSampleJob) do
        assert speaker.confirm_recognition!(by: @user, shown: token)
      end
    end
    assert_equal "confirmed_recognition", speaker.reload.naming_source
    assert speaker.training_label?, "a confirmed guess is a person's decision"
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

  test "a forget during the cut leaves no sample behind" do
    with_recognition(@account) do
      taken = snapshot
      FieldVoiceprints::Sample.stub(:cut, ->(_r, _s, &block) {
        @voice.forget! # lands between the snapshot and the store
        Tempfile.create([ "s", ".wav" ]) { |f| block.call(f.path) }
      }) do
        assert_equal :stale, FieldVoiceprints::Learning.learn!(taken, client: embeddings)
      end
    end
    assert_equal 0, FieldVoiceSample.count
    assert_nil @voice.reload.voiceprint
  end

  test "un-naming or discarding between the naming and the embedding stops the embedding" do
    client = embeddings
    with_recognition(@account) do
      taken = snapshot
      @speaker.reload.unname!
      @speaker.reload.name_as!(@voice, by: @user) # same voice again, but a new decision
      assert_equal :stale, fake_cut { FieldVoiceprints::Learning.learn!(taken, client:) }

      taken = snapshot
      @recording.discard_and_settle!
      assert_equal :stale, fake_cut { FieldVoiceprints::Learning.learn!(taken, client:) }
    end
    assert_empty client.calls
    assert_equal 0, FieldVoiceSample.count
  end

  test "switching the gate on builds nothing by itself for voices named before" do
    with_recognition(@account) do
      @account.update!(recognise_voices: false)
      assert_no_enqueued_jobs(only: FieldVoices::LearnSampleJob) { @account.update!(recognise_voices: true) }
      assert_equal 0, FieldVoiceprint.count + FieldVoiceSample.count
    end
  end

  test "prints refuse to be serialised" do
    print = store_print!(@voice)
    assert_raises(NotImplementedError) { print.as_json }
    assert_no_match print.print, print.inspect
  end

  test "the restore reset clears every print, sample and guess, keeps names, and moves every generation" do
    with_recognition(@account) { fake_cut { FieldVoiceprints::Learning.learn!(snapshot, client: embeddings) } }
    assert_equal 1, FieldVoiceSample.count
    @other.update!(recognised_voice: @voice, recognition_print_generation: 1, recognition_decision_generation: 0)
    before = @voice.reload.print_generation
    learning = @voice.learning_generation

    FieldVoiceprints.reset_all!
    assert_equal 0, FieldVoiceprint.count
    assert_equal 0, FieldVoiceSample.count
    assert_nil @other.reload.recognised_voice_id
    assert_operator @voice.reload.print_generation, :>, before
    assert_operator @voice.learning_generation, :>, learning
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

  test "a second pass finds a voice remembered since the first, and reuses the kept probe" do
    fresh = untouched_recording
    client = embeddings(voice_vector(@voice.id % 100))
    assert_nil identify!(fresh, client), "nobody remembered yet: nothing to match"
    assert_empty client.calls

    store_print!(@voice)
    assert_equal 1, identify!(fresh, client)
    speaker = fresh.speakers.first.reload
    assert_equal @voice, speaker.recognised_voice

    assert_equal 1, identify!(fresh, client)
    assert_equal @voice, speaker.reload.recognised_voice, "matching again with the same prints keeps the guess"
    assert_equal 1, client.calls.size, "the kept probe means no audio work the second time"
  end

  test "a pass that finds nothing clears a guess made with a print that's since been replaced" do
    store_print!(@voice)
    fresh = untouched_recording
    identify!(fresh, embeddings(voice_vector(@voice.id % 100)))
    speaker = fresh.speakers.first.reload
    assert_equal @voice, speaker.recognised_voice

    # Learned again from other samples: same voice, a newer print that no
    # longer sounds like this speaker.
    generation = @voice.reload.print_generation + 1
    @voice.update_columns(print_generation: generation)
    FieldVoiceprint.find_by!(field_voice: @voice).update!(generation:, print: JSON.generate(voice_vector(150)))
    restamp_cohort!(@account) # as the check would, once it has run on the new print
    assert_equal 0, identify!(fresh)
    assert_nil speaker.reload.recognised_voice_id
  end

end
