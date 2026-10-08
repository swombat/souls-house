require "test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

class Api::V1::Field::VoicesControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers
  include ApiHumanKeyHelpers

  SECRET_PRINT = "BIOMETRIC-#{SecureRandom.hex(8)}".freeze

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
    @speaker = @recording.speakers.first
    @voice = @account.field_voices.create!(name: "Tomás")
    @speaker.name_as!(@voice, by: @user)
  end

  test "a person lists voices and what is remembered, never the print" do
    store_print!(@voice, print: SECRET_PRINT)
    get api_v1_field_voices_path, headers: @headers
    assert_response :success
    tomas = response.parsed_body["voices"].find { |v| v["name"] == "Tomás" }
    assert tomas["remembered"]
    assert_equal 1, tomas["used_in"]
    assert_not_includes response.body, SECRET_PRINT
    assert_equal [], response.parsed_body["pending_enrolments"]
    assert response.parsed_body["can_change_setting"]
  end

  test "rename changes the name everywhere; a blank name is refused" do
    patch api_v1_field_voice_path(@voice), params: { name: "Tomás G" }, headers: @headers, as: :json
    assert_response :success
    assert_equal "Tomás G", @voice.reload.name

    patch api_v1_field_voice_path(@voice), params: { name: "" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal "Tomás G", @voice.reload.name
  end

  test "forget one print, forget all, delete a voice" do
    store_print!(@voice)
    delete forget_api_v1_field_voice_path(@voice), headers: @headers
    assert_response :no_content
    assert_nil FieldVoiceprint.find_by(field_voice: @voice)

    store_print!(@voice)
    store_print!(@account.field_voices.create!(name: "Priya"))
    delete forget_all_api_v1_field_voices_path, headers: @headers
    assert_response :no_content
    assert_equal 0, FieldVoiceprint.where(account: @account).count

    delete api_v1_field_voice_path(@voice), headers: @headers
    assert_response :no_content
    assert @voice.reload.discarded?
    assert_nil @speaker.reload.field_voice
  end

  test "recognition on and off" do
    patch recognition_api_v1_field_voices_path, params: { recognise_voices: true }, headers: @headers, as: :json
    assert_response :success
    assert @account.reload.recognise_voices
    patch recognition_api_v1_field_voices_path, params: { recognise_voices: false }, headers: @headers, as: :json
    assert_not @account.reload.recognise_voices
    patch recognition_api_v1_field_voices_path, params: {}, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "a pending enrolment can be removed" do
    enrolment = FieldVoiceEnrolment.create!(account: @account, field_voice: @voice, field_recording_speaker: @speaker,
      start_generation: 0, sample_ms: 12_000, consent_text_version: FieldVoiceprints::CONSENT_TEXT_VERSION,
      consented_by: @user, expires_at: 10.minutes.from_now)
    get api_v1_field_voices_path, headers: @headers
    assert_equal [ enrolment.to_param ], response.parsed_body["pending_enrolments"].map { |e| e["id"] }

    delete api_v1_field_enrolment_path(enrolment), headers: resident_headers(@user, agents(:research_assistant))
    assert_response :forbidden
    delete api_v1_field_enrolment_path(enrolment), headers: @headers
    assert_response :no_content
    assert_nil FieldVoiceEnrolment.find_by(id: enrolment.id)
  end

  test "resident keys are refused, other accounts' voices are 404, and former members reach nothing" do
    resident = resident_headers(@user, agents(:research_assistant))
    get api_v1_field_voices_path, headers: resident
    assert_response :forbidden
    delete forget_all_api_v1_field_voices_path, headers: resident
    assert_response :forbidden
    patch recognition_api_v1_field_voices_path, params: { recognise_voices: true }, headers: resident, as: :json
    assert_response :forbidden

    theirs = accounts(:another_team).field_voices.create!(name: "Theirs")
    delete api_v1_field_voice_path(theirs), headers: @headers
    assert_response :not_found
    assert theirs.reload.kept?

    end_membership!(@user, @account)
    patch recognition_api_v1_field_voices_path, params: { recognise_voices: true }, headers: @headers, as: :json
    assert_response :not_found
    assert_not @account.reload.recognise_voices
  end

end
