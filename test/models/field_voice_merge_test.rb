require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceMergeTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper
  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @recording = long_ready_recording(account: @account, user: @user, title: "Board call")
    @other_recording = long_ready_recording(account: @account, user: @user, title: "Offsite")
    @ants = @account.field_voices.create!(name: "Ants")
    @hiron = @account.field_voices.create!(name: "Ant Hiron")
    @speaker = @recording.speakers.first
    @later = @other_recording.speakers.first
    @speaker.name_as!(@ants, by: @user)
    @later.name_as!(@hiron, by: @user)
  end

  test "every speaker named either way becomes one speaker under the kept name" do
    kept = @ants.merge_into!(@hiron)

    assert_equal @hiron, kept
    assert @ants.reload.discarded?
    assert_equal @hiron.id, @speaker.reload.field_voice_id
    assert_equal "human", @speaker.naming_source, "the naming stays a person's"
    assert_equal "Ant Hiron", @speaker.display_name
    assert_match "Ant Hiron:", @recording.reload.transcript_text
    assert_no_match(/\bAnts:/, @recording.transcript_text)
  end

  test "either name can be kept" do
    @ants.merge_into!(@hiron, name: "ants")
    assert_equal "ants", @hiron.reload.name
    perform_enqueued_jobs only: FieldRecordings::RerenderTranscriptsJob
    assert_match "ants:", @other_recording.reload.transcript_text
  end

  test "a new name, the same voice, or another account's voice is refused" do
    assert_raises(FieldVoice::Merge::Refused) { @ants.merge_into!(@hiron, name: "Anthony") }
    assert_raises(FieldVoice::Merge::Refused) { @ants.merge_into!(@ants) }
    theirs = accounts(:another_team).field_voices.create!(name: "Them")
    assert_raises(FieldVoice::Merge::Refused) { @ants.merge_into!(theirs) }
    assert @ants.reload.kept?
  end

  test "two different members can't be merged, but a member's link moves to the kept voice" do
    @ants.update!(user: @user)
    @hiron.merge_into!(@ants)
    assert_equal @user, @ants.reload.user

    other = @account.field_voices.create!(name: "Priya", user: users(:regular_user))
    assert_raises(FieldVoice::Merge::Refused) { other.merge_into!(@ants) }

    solo = @account.field_voices.create!(name: "Solo")
    @ants.merge_into!(solo, name: "Ants")
    assert_equal @user, solo.reload.user, "the member link follows the person"
  end

  test "suggestions point at the kept voice and guesses from either old print are cleared" do
    third = @recording.speakers.second
    third.update!(suggested_voice: @ants, suggested_name: "Ants", recognised_voice: @hiron,
      recognition_print_generation: 1, recognition_decision_generation: 0)

    @ants.merge_into!(@hiron)

    third.reload
    assert_equal @hiron, third.suggested_voice
    assert_equal "Ant Hiron", third.suggested_name
    assert_nil third.recognised_voice_id
  end

  test "confirmed samples move with their confirmation, and the kept print is rebuilt from both" do
    with_recognition(@account) do
      a = confirmed_recording_sample!(@ants, recording: @recording, vector: voice_vector(3))
      b = confirmed_recording_sample!(@hiron, recording: @other_recording, vector: voice_vector(3))
      upload = store_print!(@ants) && @ants.samples.where(field_recording_speaker_id: nil).first
      assert upload.manually_confirmed?

      @ants.merge_into!(@hiron)

      assert_nil FieldVoiceprint.find_by(field_voice_id: @ants.id)
      [ a, b, upload ].each do |sample|
        sample.reload
        assert_equal @hiron.id, sample.field_voice_id
        assert sample.manually_confirmed?, "confirmation stands after the merge"
      end
      print = @hiron.reload.voiceprint
      assert print, "a print is rebuilt for the kept voice"
      assert_equal print.generation, @hiron.print_generation
      assert_equal 4, print.sample_count
    end
  end

  test "merging into a forgotten voice forgets what moved in" do
    store_print!(@ants)
    @hiron.forget!
    @ants.merge_into!(@hiron)
    assert_equal 0, FieldVoiceSample.where(field_voice_id: [ @ants.id, @hiron.id ]).count
    assert_nil FieldVoiceprint.find_by(field_voice_id: @hiron.id)
  end

end
