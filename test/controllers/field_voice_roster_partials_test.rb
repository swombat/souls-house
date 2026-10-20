require "test_helper"
require "support/field_recording_helpers"

class FieldVoiceRosterPartialsTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    sign_in @user
    @recording = ready_recording(account: @account, user: @user)
  end

  test "roster partial never evaluates transcript words or speaker serialization" do
    original_words = FieldRecording.instance_method(:transcript_words)
    FieldRecording.define_method(:transcript_words) { raise "Roster evaluated transcript words" }
    FieldItems.stub :speaker_json, ->(*) { flunk "Roster evaluated speaker JSON" } do
      get account_field_recording_path(@account, @recording),
        headers: partial("voices,members_without_voice,my_voice_id,show_you_hint")
      assert_response :success
    end
    props = response.parsed_body.fetch("props")
    assert props.key?("voices")
    assert props.key?("show_you_hint")
    assert_not props.key?("recording")
    assert_not props.key?("speakers")
  ensure
    FieldRecording.define_method(:transcript_words, original_words) if original_words
  end

  test "requested recording and speakers still render and skip unrelated roster" do
    FieldItems.stub :voices_json, ->(*) { flunk "Transcript partial evaluated roster" } do
      FieldItems.stub :members_without_voice_json, ->(*) { flunk "Transcript partial evaluated members" } do
        get account_field_recording_path(@account, @recording), headers: partial("recording,speakers")
        assert_response :success
      end
    end
    props = response.parsed_body.fetch("props")
    assert_not props.fetch("recording").key?("words"), "a recording refresh never resends the transcript"
    assert_not props.key?("words")
    assert_equal 2, props.fetch("speakers").size
    assert_not props.key?("voices")
  end

  test "the words partial carries the transcript alone" do
    get account_field_recording_path(@account, @recording), headers: partial("words")
    assert_response :success
    props = response.parsed_body.fetch("props")
    assert props.fetch("words").any?
    assert_not props.key?("recording")
    assert_not props.key?("speakers")
  end

  private

  def partial(props)
    {
      "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest,
      "X-Inertia-Partial-Component" => "field/recordings/show", "X-Inertia-Partial-Data" => props
    }
  end

end
