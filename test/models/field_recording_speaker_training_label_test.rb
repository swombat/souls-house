require "test_helper"
require "support/field_recording_helpers"

# Which namings may teach a voice print (spec 2026-10-19 §5): only a person's
# decision, on a voice that's still kept. Everything else fails closed.
class FieldRecordingSpeakerTrainingLabelTest < ActiveSupport::TestCase

  include FieldRecordingHelpers

  setup do
    @account = accounts(:personal_account)
    @recording = long_ready_recording(account: @account, user: users(:user_1))
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "Tomás")
  end

  {
    "human" => true, "confirmed_suggestion" => true, "confirmed_recognition" => true,
    "auto_recognition" => true, "machine" => false, "unknown" => false, nil => false
  }.each do |source, expected|
    test "a kept voice named by #{source.inspect} #{expected ? 'is' : 'is not'} a training label" do
      @speaker.update_columns(field_voice_id: @voice.id, naming_source: source)
      assert_equal expected, @speaker.reload.training_label?
    end
  end

  test "a person's naming isn't a training label without a voice, or once the voice is discarded" do
    @speaker.update_columns(field_voice_id: nil, naming_source: "human")
    assert_not @speaker.reload.training_label?

    @speaker.update_columns(field_voice_id: @voice.id)
    @voice.update_columns(discarded_at: Time.current)
    assert_not @speaker.reload.training_label?
  end

end
