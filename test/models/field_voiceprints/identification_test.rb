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

  test "a print rebuilt while embedding is not used" do
    with_recognition(@account) do
      store_print!(@voice, vector: voice_vector(3))
      client = FakeVoiceEmbeddings.new({ default: voice_vector(3) })
      client.define_singleton_method(:embed) do |wav|
        voice = FieldVoice.find_by!(name: "Tomás")
        voice.update_columns(print_generation: voice.print_generation + 1)
        FakeVoiceEmbeddings.instance_method(:embed).bind_call(self, wav)
      end
      assert_equal 0, run_identify(client)
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
      FieldVoiceprints::Validation.stub(:run!, ->(_account) { @voice.voiceprint.update!(validated: true, validated_digest: @voice.voiceprint.sample_digest) }) do
        assert_enqueued_with(job: FieldRecordings::IdentifyJob, args: [ @recording.id ]) do
          FieldVoices::ValidatePrintsJob.perform_now(@account.id)
        end
      end
    end
  end

end
