require "test_helper"
require "support/field_recording_helpers"

# Guessing unnamed speakers in the house (spec 2026-10-19 §8).
class FieldVoiceprints::IdentificationTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker = @recording.speakers.find_by!(label: "speaker_0")
    @voice = @account.field_voices.create!(name: "Tomás")
    @other_voice = @account.field_voices.create!(name: "Priya")
  end

  def fake_cut(&)
    FieldVoiceprints::Sample.stub(:cut, ->(_recording, _segments, &block) {
      Tempfile.create([ "s", ".wav" ]) { |file| file.write("RIFF"); file.flush; block.call(file.path) }
    }, &)
  end

  def run_identify(client)
    fake_cut { FieldVoiceprints::Identification.run!(@recording.reload, client:) }
  end

  test "an undecided speaker close to an active print gets a guess, and its embedding is kept" do
    with_recognition(@account) do
      print = store_print!(@voice, vector: voice_vector(3))
      confirmed = FieldVoiceprints::Limits.confirmed_samples(@voice)
      assert_equal 2, confirmed.size
      assert_equal FieldVoiceprints::Learning.digest(confirmed), print.sample_digest
      store_print!(@other_voice, vector: voice_vector(7))
      client = FakeVoiceEmbeddings.new({ default: voice_vector(3, noise: 0.05) })

      assert_equal 1, run_identify(client)
      @speaker.reload
      assert_equal @voice.id, @speaker.recognised_voice_id
      assert_equal @voice.reload.print_generation, @speaker.recognition_print_generation
      assert_operator @speaker.recognition_confidence, :>=, 55
      assert @speaker.recognition?
      assert_equal FieldVoiceprints::Profiles::ECAPA, @speaker.probe_profile
      assert_not_includes @speaker.as_json.keys, "probe_embedding", "a kept embedding is never serialised"
      assert_not_includes @speaker.to_json, "probe"

      assert_equal 1, run_identify(client)
      assert_equal 1, client.calls.size, "matching again uses the kept embedding"
    end
  end

  test "a sure match from an active print names the speaker on its own, marked, with a candidate sample queued, and Not them undoes it" do
    with_recognition(@account, naming: true) do
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7))
      client = FakeVoiceEmbeddings.new({ default: voice_vector(3, noise: 0.05) })

      assert_enqueued_with(job: FieldVoices::LearnSampleJob) do
        assert_enqueued_with(job: FieldItems::RefreshSummaryJob) do
          assert_equal 1, run_identify(client)
        end
      end
      @speaker.reload
      assert_equal [ @voice.id, "auto_recognition", nil ], [ @speaker.field_voice_id, @speaker.naming_source, @speaker.named_by ]
      assert @speaker.auto_named?
      assert @speaker.training_label?, "a candidate sample, for a person to accept"
      assert_operator @speaker.auto_named_confidence, :>=, 70
      assert_nil @speaker.recognised_voice_id, "a naming is not a chip"
      assert_nil @speaker.probe_embedding
      assert_includes @recording.reload.transcript_text, "Tomás"

      json = FieldItems.speaker_json(@speaker)
      assert json[:named]
      assert_equal @speaker.auto_named_confidence, json.dig(:auto_named, :confidence)
      assert_nil json[:recognition]

      # "Not them" is a person's decision: back to "Speaker N", and nothing
      # guesses at this speaker again.
      @speaker.unname!
      @speaker.reload
      assert_nil @speaker.field_voice_id
      assert_nil @speaker.auto_named_confidence
      assert_nil FieldItems.speaker_json(@speaker)[:auto_named]
      assert_equal 0, run_identify(client)
      assert_nil @speaker.reload.recognised_voice_id

      # A person's own naming afterwards carries no match score.
      @speaker.name_as!(@other_voice, by: @user)
      assert_nil @speaker.reload.auto_named_confidence
      assert_not @speaker.auto_named?
    end
  end

  test "a sure match only suggests while naming is off, and a guess under the naming line stays a chip" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7))
      assert_equal 1, run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3, noise: 0.05) }))
      @speaker.reload
      assert_nil @speaker.field_voice_id
      assert_equal [ @voice.id, true ], [ @speaker.recognised_voice_id, @speaker.recognition_checked ]

      @account.update!(auto_name_voices: true)
      @speaker.update!(**FieldRecordingSpeaker::RECOGNITION_FIELDS, probe_embedding: nil, probe_profile: nil)
      # 0.62 to Tomás and 0.30 to Priya: a guess (≥ 0.55, lead 0.32), but
      # under the 0.70 naming line.
      between = Array.new(192, 0.0)
      between[3] = 0.62
      between[7] = 0.30
      between[11] = Math.sqrt(1 - (0.62**2) - (0.30**2))
      assert_equal 1, run_identify(FakeVoiceEmbeddings.new({ default: between }))
      @speaker.reload
      assert_nil @speaker.field_voice_id
      assert_equal [ @voice.id, true, 62 ], [ @speaker.recognised_voice_id, @speaker.recognition_checked, @speaker.recognition_confidence ]
    end
  end

  test "an unchecked print's hint never names a speaker, however close" do
    with_recognition(@account, naming: true) do
      store_print!(@voice, vector: voice_vector(3), active: false)
      assert_equal 1, run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
      @speaker.reload
      assert_nil @speaker.field_voice_id
      assert_equal [ @voice.id, false ], [ @speaker.recognised_voice_id, @speaker.recognition_checked ]
    end
  end

  test "a sure match needs the lead over unchecked voices too: a close unchecked competitor keeps it a chip" do
    with_recognition(@account, naming: true) do
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7), active: false)
      # 0.76 to Tomás (checked) and 0.66 to Priya (unchecked): sure against
      # the checked voices alone, not against every voice this Field knows.
      between = Array.new(192, 0.0)
      between[3] = 0.75
      between[7] = 0.65
      norm = Math.sqrt((0.75**2) + (0.65**2))
      between = between.map { |value| value / norm }
      assert_equal 1, run_identify(FakeVoiceEmbeddings.new({ default: between }))
      @speaker.reload
      assert_nil @speaker.field_voice_id, "named nobody"
      assert_equal [ @voice.id, true ], [ @speaker.recognised_voice_id, @speaker.recognition_checked ]
      # Against the checked voices alone the same guess would have cleared
      # the line; the competitor is what keeps it a chip.
      assert FieldVoiceprints::Matching.sure?([ @voice.id, 0.756, 0.756 ])
    end
  end

  test "an unvalidated print only hints, said as unchecked, and confirming the hint names the speaker and teaches it" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3), active: false)
      assert_equal 1, run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
      @speaker.reload
      assert_equal [ @voice.id, false ], [ @speaker.recognised_voice_id, @speaker.recognition_checked ]
      assert_equal false, FieldItems.speaker_json(@speaker).dig(:recognition, :checked)

      assert_enqueued_with(job: FieldVoices::LearnSampleJob) do
        assert @speaker.confirm_recognition!(by: @user, shown: @speaker.recognition_token)
      end
      assert_equal [ @voice.id, "confirmed_recognition" ], [ @speaker.reload.field_voice_id, @speaker.naming_source ]
      assert_nil @speaker.recognition_checked
    end
  end

  test "an active print's guess is checked, and an unchecked print never takes a speaker an active one claims" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7), active: false)
      assert_equal 1, run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3, noise: 0.05) }))
      @speaker.reload
      assert_equal [ @voice.id, true ], [ @speaker.recognised_voice_id, @speaker.recognition_checked ]
      assert_equal true, FieldItems.speaker_json(@speaker).dig(:recognition, :checked)
    end
  end

  test "a speaker no active print claims gets the unchecked print's hint, under the same match rules" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7), active: false)
      assert_equal 1, run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(7, noise: 0.05) }))
      @speaker.reload
      assert_equal [ @other_voice.id, false ], [ @speaker.recognised_voice_id, @speaker.recognition_checked ]

      # Sounding like no one stays unguessed, checked or not.
      @speaker.update!(**FieldRecordingSpeaker::RECOGNITION_FIELDS, probe_embedding: nil, probe_profile: nil)
      assert_equal 0, run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(11) }))
      assert_nil @speaker.reload.recognised_voice_id
    end
  end

  test "a speaker a person has decided about is never guessed" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      @speaker.ignore!(by: @user)
      @speaker.unignore!
      client = FakeVoiceEmbeddings.new({ default: voice_vector(3) })
      assert_equal 0, run_identify(client)
      assert_nil @speaker.reload.recognised_voice_id, "decided once, never guessed"
      assert_nil @speaker.probe_embedding
    end
  end

  test "a competitor that becomes active while embedding means nothing is written, and the job runs again" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      account = @account
      helper = self
      between = Array.new(192, 0.0)
      between[3] = 0.75
      between[7] = Math.sqrt(1 - (0.75**2)) # 0.75 to Tomás, 0.66 to Priya: a margin of 0.09
      client = FakeVoiceEmbeddings.new({ default: between })
      client.define_singleton_method(:embed) do |wav|
        helper.store_print!(account.field_voices.find_by!(name: "Priya"), vector: helper.voice_vector(7))
        FakeVoiceEmbeddings.instance_method(:embed).bind_call(self, wav)
      end
      assert_equal :changed, run_identify(client), "alone, Tomás would have won; with Priya the margin is too small"
      assert_nil @speaker.reload.recognised_voice_id
      assert_nil @speaker.probe_embedding

      FieldVoiceprints::Identification.stub(:run!, :changed) do
        assert_enqueued_with(job: FieldRecordings::IdentifyJob, args: [ @recording.id, 1 ]) do
          FieldRecordings::IdentifyJob.perform_now(@recording.id)
        end
      end
    end
  end

  test "Forget all while embedding keeps no probe and makes no guess" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      account = @account
      client = FakeVoiceEmbeddings.new({ default: voice_vector(3) })
      client.define_singleton_method(:embed) do |wav|
        FieldVoiceprints.forget_all!(account)
        FakeVoiceEmbeddings.instance_method(:embed).bind_call(self, wav)
      end
      assert_nil run_identify(client)
      @speaker.reload
      assert_nil @speaker.probe_embedding, "a forgotten account's probe must not come back"
      assert_nil @speaker.recognised_voice_id
    end
  end

  # Mira's second review, finding 1.
  test "a guess stops standing, and can't be confirmed, once the cohort it was made in changes" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7))
      run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
      token = @speaker.reload.recognition_token
      assert_equal @voice.id, @speaker.recognised_voice_id

      @other_voice.forget!
      assert_not @speaker.reload.confirm_recognition!(by: @user, shown: token), "Tomás's print is unchanged, but its verdict isn't"
      assert_nil @speaker.reload.field_voice_id

      FieldVoiceprints::Validation.run!(@account) # one surviving voice has too few negative queries to validate
      assert_empty FieldVoiceprints::Identification.active_prints(@account)
      assert_nil @speaker.reload.recognised_voice_id, "publishing a new verdict clears guesses made under the old one"
    end
  end

  # Mira's third look: the same winner, rematched under a new key, must not
  # accept the old chip's token.
  test "an old token can't confirm or dismiss a guess rematched to the same winner under a new key" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7))
      run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
      old_token = @speaker.reload.recognition_token

      @other_voice.voiceprint.destroy!
      store_print!(@other_voice.reload, vector: voice_vector(8)) # Priya relearned: a new cohort, Tomás unchanged
      run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
      fresh_token = @speaker.reload.recognition_token
      assert_equal old_token.except(:cohort), fresh_token.except(:cohort), "same winner, same generations"
      assert_not_equal old_token[:cohort], fresh_token[:cohort]

      assert_not @speaker.confirm_recognition!(by: @user, shown: old_token)
      assert_not @speaker.reload.dismiss_recognition!(shown: old_token)
      assert_equal @voice.id, @speaker.reload.recognised_voice_id, "the stale tokens changed nothing"
      assert @speaker.confirm_recognition!(by: @user, shown: fresh_token)
      assert_equal @voice.id, @speaker.reload.field_voice_id
    end
  end

  test "a change in which prints are active, with the same cohort, means nothing is written" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7))
      other = @other_voice
      client = FakeVoiceEmbeddings.new({ default: voice_vector(3) })
      client.define_singleton_method(:embed) do |wav|
        other.voiceprint.update!(validated: false) # a verdict, not a cohort change
        FakeVoiceEmbeddings.instance_method(:embed).bind_call(self, wav)
      end
      assert_equal :changed, run_identify(client)
      assert_nil @speaker.reload.recognised_voice_id
    end
  end

  test "dismissing a name suggestion clears a kept embedding" do
    @speaker.update!(probe_embedding: "[1]", probe_profile: "ecapa-test", suggested_name: "Tomás",
      suggestion_generation: @speaker.decision_generation)
    assert @speaker.dismiss_suggestion!(@speaker.decision_generation)
    assert_nil @speaker.reload.probe_embedding
  end

  test "a print rebuilt while embedding is not used" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      client = FakeVoiceEmbeddings.new({ default: voice_vector(3) })
      client.define_singleton_method(:embed) do |wav|
        voice = FieldVoice.find_by!(name: "Tomás")
        voice.update_columns(print_generation: voice.print_generation + 1)
        FakeVoiceEmbeddings.instance_method(:embed).bind_call(self, wav)
      end
      assert_equal :changed, run_identify(client)
      assert_nil @speaker.reload.recognised_voice_id
    end
  end

  test "nothing runs with recognition off" do
    store_print!(@voice, vector: voice_vector(3))
    assert_nil run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
  end

  test "confirming a guess names the speaker and teaches the print" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
      token = @speaker.reload.recognition_token

      assert_enqueued_with(job: FieldVoices::LearnSampleJob) do
        assert @speaker.confirm_recognition!(by: @user, shown: token)
      end
      assert_equal [ @voice.id, "confirmed_recognition" ], [ @speaker.reload.field_voice_id, @speaker.naming_source ]
      assert_nil @speaker.probe_embedding
    end
  end

  test "a change in which prints may guess matches the account's recordings again" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3), active: false)
      validate = ->(_account) { @voice.voiceprint.update!(validated: true) && restamp_cohort!(@account) && {} }
      FieldVoiceprints::Validation.stub(:run!, validate) do
        assert_enqueued_with(job: FieldRecordings::IdentifyJob, args: [ @recording.id ]) do
          FieldVoices::ValidatePrintsJob.perform_now(@account.id)
        end
      end
    end
  end


  test "a print learned before the check and left unchecked by it still matches the account's recordings again, once" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3), active: false)
      unchanged = ->(_account) { {} } # the check runs and leaves every verdict as it was
      FieldVoiceprints::Validation.stub(:run!, unchanged) do
        assert_enqueued_with(job: FieldRecordings::IdentifyJob, args: [ @recording.id ]) do
          FieldVoices::ValidatePrintsJob.perform_now(@account.id)
        end
        assert_no_enqueued_jobs(only: FieldRecordings::IdentifyJob) do
          FieldVoices::ValidatePrintsJob.perform_now(@account.id)
        end
      end
    end
  end


  test "if scheduling the rematch fails, the snapshot isn't recorded, so the retry schedules it" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3), active: false)
      FieldVoiceprints::Validation.stub(:run!, ->(_account) { {} }) do
        # A real enqueue failure: the adapter raises EnqueueError, Active Job
        # rescues it, and perform_later returns false.
        failing = ActiveJob::QueueAdapters::AbstractAdapter.new
        def failing.enqueue(*) = raise(ActiveJob::EnqueueError, "queue down")
        FieldRecordings::IdentifyJob.stub(:queue_adapter, failing) do
          assert_equal false, FieldRecordings::IdentifyJob.perform_later(@recording.id), "the contract this relies on"
          FieldVoices::ValidatePrintsJob.perform_now(@account.id)
        end
        assert_nil @account.reload.field_matched_cohort
        assert_enqueued_with(job: FieldRecordings::IdentifyJob, args: [ @recording.id ]) do
          FieldVoices::ValidatePrintsJob.perform_now(@account.id)
        end
        assert_equal FieldVoiceprints::Cohort.active(@account).last, @account.reload.field_matched_cohort
      end
    end
  end

end
