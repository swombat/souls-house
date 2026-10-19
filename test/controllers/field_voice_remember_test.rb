require "test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

# Forget stops a voice learning; "Remember again" turns learning back on and
# learns afresh from the names people gave, on the page and through the API.
class FieldVoiceRememberTest < ActionDispatch::IntegrationTest

  include ActiveJob::TestHelper
  include FieldRecordingHelpers
  include ApiHumanKeyHelpers

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    @recording = long_ready_recording(account: @account, user: @user)
    @speaker = @recording.speakers.find_by!(label: "speaker_0")
    @voice = @account.field_voices.create!(name: "Tomás")
  end

  test "recognition is on for a new account, and the Voices page offers the switch when the house can learn" do
    assert Account.new.recognise_voices
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    with_recognition(@account) do
      get account_field_voices_path(@account)
      props = inertia_props["props"]
      assert props["house_recognition"]
      assert props["recognise_voices"]
    end
  end

  test "forget then remember again on the page queues learning from the voice's namings" do
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    with_recognition(@account) do
      @speaker.name_as!(@voice, by: @user)
      delete forget_account_field_voice_path(@account, @voice)
      assert_not @voice.reload.remember?
      clear_enqueued_jobs

      assert_enqueued_with(job: FieldVoices::LearnSampleJob) do
        post remember_account_field_voice_path(@account, @voice)
      end
      assert @voice.reload.remember?
      row = FieldItems.voice_page_json(@voice, 1)
      assert_equal [ true, false, false ], row.values_at(:remember, :remembered, :guessing)
    end
  end

  test "remember again through the API" do
    with_recognition(@account) do
      @voice.forget!
      post remember_api_v1_field_voice_path(@voice), headers: human_headers(@user, @account)
      assert_response :no_content
      assert @voice.reload.remember?
    end
  end

end
