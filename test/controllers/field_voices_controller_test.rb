require "test_helper"
require "support/field_recording_helpers"

class FieldVoicesControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  SECRET_PRINT = "BIOMETRIC-#{SecureRandom.hex(8)}".freeze

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
    @recording = long_ready_recording(account: @account, user: @user, title: "Board call")
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "Tomás")
    @speaker.name_as!(@voice, by: @user)
  end

  def props
    @inertia_props = nil
    inertia_props["props"]
  end

  test "forgetting works with recognition off, and so does forgetting everything" do
    store_print!(@voice, print: SECRET_PRINT)
    delete forget_account_field_voice_path(@account, @voice)
    assert_nil FieldVoiceprint.find_by(field_voice: @voice)

    store_print!(@voice)
    other = @account.field_voices.create!(name: "Priya")
    store_print!(other)
    delete forget_all_account_field_voices_path(@account)
    assert_equal 0, FieldVoiceprint.where(account: @account).count
  end

  test "remembering needs both gates and a ticked box" do
    post account_field_recording_speaker_enrolments_path(@account, @recording, @speaker), params: { enrolment: { consent: "1" } }
    assert_equal 0, FieldVoiceEnrolment.count, "gate shut"

    with_recognition(@account) do
      post account_field_recording_speaker_enrolments_path(@account, @recording, @speaker), params: { enrolment: { consent: "0" } }
      assert_equal 0, FieldVoiceEnrolment.count, "box not ticked"

      FieldVoiceprints::Sample.stub(:cut, ->(_r, _s, &block) { Tempfile.create([ "s", ".wav" ]) { |f| block.call(f.path) } }) do
        post account_field_recording_speaker_enrolments_path(@account, @recording, @speaker), params: { enrolment: { consent: "1" } }
      end
      assert_equal 1, FieldVoiceEnrolment.count

      get account_field_recording_path(@account, @recording)
      shown = props
      assert shown["speakers"].first.dig("pending_enrolment", "sample_url").present?
      assert shown["recognition_enabled"]

      delete account_field_voice_enrolment_path(@account, FieldVoiceEnrolment.last)
      assert_equal 0, FieldVoiceEnrolment.count, "'not them' throws the sample away"
    end
  end

  test "another account's voice or speaker can't be reached" do
    theirs = accounts(:another_team).field_voices.create!(name: "Them")
    delete forget_account_field_voice_path(@account, theirs)
    assert_response :not_found

    their_recording = long_ready_recording(account: accounts(:another_team), user: @user)
    post account_field_recording_speaker_enrolments_path(@account, their_recording, their_recording.speakers.first),
      params: { enrolment: { consent: "1" } }
    assert_response :not_found
  end

  test "a member who can manage the account turns recognition on and off" do
    patch recognition_account_field_voices_path(@account), params: { recognise_voices: true }
    assert @account.reload.recognise_voices
    patch recognition_account_field_voices_path(@account), params: { recognise_voices: false }
    assert_not @account.reload.recognise_voices
  end

  test "the Voices page lists names and what is remembered" do
    store_print!(@voice)
    with_recognition(@account) { get account_field_voices_path(@account) }

    shown = props
    assert_equal "field/voices", inertia_props["component"]
    tomas = shown["voices"].find { |v| v["name"] == "Tomás" }
    assert tomas["remembered"]
    assert_equal 12, tomas["sample_seconds"]
    assert_equal 1, tomas["used_in"]
    assert_equal 30, shown["backup_retention_days"]
    assert shown["house_recognition"]
  end

  test "no print ever reaches a page or the resident API" do
    store_print!(@voice, print: SECRET_PRINT)
    resident = agents(:research_assistant)
    key = ApiKey.generate_for(@user, name: "Field tests", agent: resident)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }

    with_recognition(@account) do
      bodies = []
      get account_field_path(@account, tab: "recordings")
      bodies << response.body
      get account_field_recording_path(@account, @recording)
      bodies << response.body
      get account_field_voices_path(@account)
      bodies << response.body
      get api_v1_field_recordings_path, headers: headers
      bodies << response.body
      get api_v1_field_recording_path(@recording), headers: headers
      bodies << response.body

      bodies.each do |body|
        assert_not_includes body, SECRET_PRINT
        assert_no_match(/&quot;print&quot;|"print"\s*:/, body)
      end
    end
  end

  test "deleting a voice from the page forgets it and un-names its speakers" do
    store_print!(@voice)
    delete account_field_voice_path(@account, @voice)
    assert @voice.reload.discarded?
    assert_nil FieldVoiceprint.find_by(field_voice_id: @voice.id)
    assert_equal "Speaker 1", @speaker.reload.display_name
  end

end
