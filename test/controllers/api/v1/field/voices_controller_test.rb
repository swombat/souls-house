require "test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

class Api::V1::Field::VoicesControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers
  include ApiHumanKeyHelpers


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
    secret = voice_vector(3, noise: 0.37, seed: 7)
    store_print!(@voice, vector: secret)
    get api_v1_field_voices_path, headers: @headers
    assert_response :success
    tomas = response.parsed_body["voices"].find { |v| v["name"] == "Tomás" }
    assert tomas["remember"]
    assert tomas["remembered"]
    assert tomas["guessing"]
    assert_equal 2, tomas["recordings"]
    assert_equal 12, tomas["sample_seconds"]
    assert_equal 1, tomas["used_in"]
    secret.first(5).each { |value| assert_not_includes response.body, value.to_s }
    assert_no_match(/"print"\s*:/, response.body)
    assert_not response.parsed_body.key?("pending_enrolments"), "there are no enrolments any more"
    assert response.parsed_body["recognise_voices"], "on by default"
    assert_not response.parsed_body["house_recognition"], "no voice service configured here"
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

  test "forget one voice, remember it again, forget all, delete a voice" do
    store_print!(@voice)
    delete forget_api_v1_field_voice_path(@voice), headers: @headers
    assert_response :no_content
    assert_nil FieldVoiceprint.find_by(field_voice: @voice)
    assert_not @voice.reload.remember?

    post remember_api_v1_field_voice_path(@voice), headers: @headers
    assert_response :no_content
    assert @voice.reload.remember?
    assert_not @voice.remembered?, "nothing forgotten comes back"

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

    post remember_api_v1_field_voice_path(@voice), headers: resident
    assert_response :forbidden

    @account.update!(recognise_voices: false)
    end_membership!(@user, @account)
    patch recognition_api_v1_field_voices_path, params: { recognise_voices: true }, headers: @headers, as: :json
    assert_response :not_found
    assert_not @account.reload.recognise_voices
  end

end
