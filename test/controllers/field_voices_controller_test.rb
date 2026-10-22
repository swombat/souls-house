require "test_helper"
require "support/field_recording_helpers"

class FieldVoicesControllerTest < ActionDispatch::IntegrationTest

  include FieldRecordingHelpers

  # A print with distinctive values, so any leak of it would show.
  SECRET_VECTOR_SEED = 7

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

  test "a manager sees paused conversion and can explicitly retry it" do
    Setting.instance.update!(voice_embedding_profile: FieldVoiceprints::Profiles::WESPEAKER)
    @account.update!(voice_conversion_status: "blocked", voice_conversion_error: "Retained audio is unavailable.")
    get account_field_voices_path(@account)
    assert_equal "blocked", props.dig("voice_conversion", "state")
    assert_equal "Retained audio is unavailable.", props.dig("voice_conversion", "message")
    assert_enqueued_with(job: FieldVoices::ConvertProfileJob, args: [ @account.id ]) do
      post retry_conversion_account_field_voices_path(@account)
    end
    assert_redirected_to account_field_voices_path(@account)
    post retry_conversion_account_field_voices_path(accounts(:another_team))
    assert_response :not_found
  end

  test "forgetting works with recognition off, and so does forgetting everything" do
    @account.update!(recognise_voices: false)
    store_print!(@voice)
    delete forget_account_field_voice_path(@account, @voice)
    assert_nil FieldVoiceprint.find_by(field_voice: @voice)
    assert_not @voice.reload.remember?

    store_print!(@voice)
    other = @account.field_voices.create!(name: "Priya")
    store_print!(other)
    delete forget_all_account_field_voices_path(@account)
    assert_equal 0, FieldVoiceprint.where(account: @account).count
  end

  test "another account's voice can't be forgotten or remembered" do
    theirs = accounts(:another_team).field_voices.create!(name: "Them")
    store_print!(theirs)
    delete forget_account_field_voice_path(@account, theirs)
    assert_response :not_found
    assert theirs.reload.remembered?

    theirs.forget!
    post remember_account_field_voice_path(@account, theirs)
    assert_response :not_found
    assert_not theirs.reload.remember?
  end

  test "a member who can manage the account turns recognition on and off" do
    assert @account.recognise_voices, "on by default"
    patch recognition_account_field_voices_path(@account), params: { recognise_voices: false }
    assert_not @account.reload.recognise_voices
    patch recognition_account_field_voices_path(@account), params: { recognise_voices: true }
    assert @account.reload.recognise_voices
  end

  test "the Voices page lists names and what is remembered" do
    store_print!(@voice)
    with_recognition(@account) { get account_field_voices_path(@account) }

    shown = props
    assert_equal "field/voices", inertia_props["component"]
    tomas = shown["voices"].find { |v| v["name"] == "Tomás" }
    assert tomas["remember"]
    assert tomas["remembered"]
    assert tomas["guessing"], "the print is validated on the samples it is built from"
    assert_equal 2, tomas["recordings"]
    assert_equal 12, tomas["sample_seconds"]
    assert tomas["learned_at"].present?
    assert_equal 1, tomas["used_in"]
    assert_not shown.key?("backup_retention_days")
    assert shown["house_recognition"]
  end

  test "no print ever reaches a page or the resident API" do
    secret = voice_vector(3, noise: 0.37, seed: SECRET_VECTOR_SEED)
    store_print!(@voice, vector: secret)
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
        secret.first(5).each { |value| assert_not_includes body, value.to_s }
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

  test "the actual roster usage follows naming un-naming and relinking" do
    get account_field_voices_path(@account)
    assert_equal 1, props["voices"].find { |voice| voice["id"] == @voice.to_param }["used_in"]

    @speaker.unname!
    get account_field_voices_path(@account)
    assert_equal 0, props["voices"].find { |voice| voice["id"] == @voice.to_param }["used_in"]

    other = @account.field_voices.create!(name: "Other speaker")
    @speaker.name_as!(other, by: @user)
    get account_field_voices_path(@account)
    assert_equal 0, props["voices"].find { |voice| voice["id"] == @voice.to_param }["used_in"]
    assert_equal 1, props["voices"].find { |voice| voice["id"] == other.to_param }["used_in"]
  end

  test "recording member options and my voice follow explicit member linking" do
    team = accounts(:team_account)
    recording = long_ready_recording(account: team, user: @user)
    member = users(:existing_user)
    get account_field_recording_path(team, recording)
    assert_includes props["members_without_voice"].map { |row| row["user_id"] }, member.id
    assert_nil props["my_voice_id"]

    FieldVoice.for_member!(account: team, user: member, by: @user)
    mine = FieldVoice.for_member!(account: team, user: @user, by: @user)
    get account_field_recording_path(team, recording)
    assert_not_includes props["members_without_voice"].map { |row| row["user_id"] }, member.id
    assert_equal mine.to_param, props["my_voice_id"]
    assert props["voices"].find { |row| row["id"] == mine.to_param }["member"]
  end

  test "remembering again after a forget learns afresh from people's namings and brings nothing back" do
    store_print!(@voice)
    FieldVoice.find(@voice.id).forget!
    with_recognition(@account) do
      assert_enqueued_with(job: FieldVoices::LearnSampleJob) do
        post remember_account_field_voice_path(@account, @voice)
      end
    end
    assert_redirected_to account_field_voices_path(@account)
    assert @voice.reload.remember?
    assert_not @voice.remembered?, "the forgotten print doesn't come back"
  end

  test "merging one speaker into another keeps the chosen name and opens the kept speaker" do
    other = @account.field_voices.create!(name: "Tomás Ruiz")
    post merge_account_field_voice_path(@account, @voice), params: { into: other.to_param, name: "Tomás Ruiz" }
    assert_redirected_to account_field_voices_path(@account, voice: other.to_param)
    assert @voice.reload.discarded?
    assert_equal other, @speaker.reload.field_voice
  end

  test "a refused merge comes back as an error, and another account's voice is not found" do
    other = @account.field_voices.create!(name: "Priya")
    post merge_account_field_voice_path(@account, @voice), params: { into: other.to_param, name: "Someone else" }
    assert_response :redirect
    assert @voice.reload.kept?

    theirs = accounts(:another_team).field_voices.create!(name: "Them")
    post merge_account_field_voice_path(@account, @voice), params: { into: theirs.to_param }
    assert @voice.reload.kept?
    assert theirs.reload.kept?
    post merge_account_field_voice_path(@account, theirs), params: { into: @voice.to_param }
    assert_response :not_found
  end

end
