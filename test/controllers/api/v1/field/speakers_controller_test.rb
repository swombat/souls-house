require "test_helper"
require "support/field_recording_helpers"
require "support/api_human_key_helpers"

class Api::V1::Field::SpeakersControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers
  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
    @recording = ready_recording(account: @account, user: @user, title: "Board call")
    @speaker = @recording.speakers.first
  end

  def name_speaker(params, headers: @headers, speaker: @speaker, recording: @recording)
    patch api_v1_field_recording_speaker_path(recording, speaker), params: params, headers: headers, as: :json
  end

  test "naming a speaker makes a new voice, and the transcript follows" do
    name_speaker({ name: "Priya" })
    assert_response :success
    assert_equal "Priya", response.parsed_body.dig("speaker", "name")
    assert_equal @account.field_voices.kept.find_by!(name: "Priya"), @speaker.reload.field_voice
    assert_includes @recording.reload.transcript_text, "Priya: hello"
  end

  test "a name that matches a voice asks 'same Priya?' until link_existing" do
    priya = @account.field_voices.create!(name: "Priya")
    name_speaker({ name: "priya" })
    assert_response :conflict
    assert_equal priya.to_param, response.parsed_body.dig("match", "voice_id")
    assert_nil @speaker.reload.field_voice

    name_speaker({ name: "priya", link_existing: true })
    assert_response :success
    assert_equal priya, @speaker.reload.field_voice
  end

  test "me, a voice by id, a member, and unname" do
    name_speaker({ me: true })
    assert_response :success
    assert_equal @user, @speaker.reload.field_voice.user

    other = @recording.speakers.last
    voice = @account.field_voices.create!(name: "Tomás")
    name_speaker({ voice_id: voice.to_param }, speaker: other)
    assert_response :success
    assert_equal voice, other.reload.field_voice

    name_speaker({ unname: true })
    assert_response :success
    assert_nil @speaker.reload.field_voice
    assert_equal "Speaker 1", response.parsed_body.dig("speaker", "name")
  end

  test "a member of the account who has no voice yet" do
    team = accounts(:team_account)
    member = team.memberships.where.not(user: @user).where.not(confirmed_at: nil).first.user
    recording = ready_recording(account: team, user: @user)
    speaker = recording.speakers.first
    name_speaker({ member_user_id: member.id }, headers: human_headers(@user, team), recording: recording, speaker: speaker)
    assert_response :success
    assert_equal member, speaker.reload.field_voice.user

    name_speaker({ member_user_id: users(:site_admin_user).id }, headers: human_headers(@user, team),
      recording: recording, speaker: recording.speakers.last)
    assert_response :not_found, "someone outside the account"
  end

  test "nothing chosen, or an invalid name, is refused" do
    name_speaker({})
    assert_response :unprocessable_entity
    name_speaker({ name: "x" * 101 })
    assert_response :unprocessable_entity
    assert_nil @speaker.reload.field_voice
  end

  test "resident keys are refused, other accounts are 404, and so is a voice from elsewhere" do
    name_speaker({ name: "Priya" }, headers: resident_headers(@user, agents(:research_assistant)))
    assert_response :forbidden

    theirs = ready_recording(account: accounts(:another_team), user: @user)
    name_speaker({ name: "Priya" }, recording: theirs, speaker: theirs.speakers.first)
    assert_response :not_found

    elsewhere = accounts(:another_team).field_voices.create!(name: "Elsewhere")
    name_speaker({ voice_id: elsewhere.to_param })
    assert_response :not_found
    assert_nil @speaker.reload.field_voice
  end

end
