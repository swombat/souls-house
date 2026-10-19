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
      store_print!(@voice, vector: voice_vector(3))
      store_print!(@other_voice, vector: voice_vector(7))
      client = FakeVoiceEmbeddings.new({ default: voice_vector(3, noise: 0.05) })

      assert_equal 1, run_identify(client)
      @speaker.reload
      assert_equal @voice.id, @speaker.recognised_voice_id
      assert_equal @voice.reload.print_generation, @speaker.recognition_print_generation
      assert_operator @speaker.recognition_confidence, :>=, 55
      assert @speaker.recognition?
      assert_equal "ecapa-test", @speaker.probe_profile
      assert_not_includes @speaker.as_json.keys, "probe_embedding", "a kept embedding is never serialised"
      assert_not_includes @speaker.to_json, "probe"

      assert_equal 1, run_identify(client)
      assert_equal 1, client.calls.size, "matching again uses the kept embedding"
    end
  end

  test "an unvalidated print never guesses" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3), active: false)
      assert_nil run_identify(FakeVoiceEmbeddings.new({ default: voice_vector(3) }))
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
      between = Array.new(FieldVoiceprints::VoiceEmbeddings::DIMENSIONS, 0.0)
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

      FieldVoiceprints::Validation.run!(@account) # no survivors: one print, no samples to check it with
      assert_empty FieldVoiceprints::Identification.active_prints(@account)
      assert_nil @speaker.reload.recognised_voice_id, "publishing a new verdict clears guesses made under the old one"
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

end
