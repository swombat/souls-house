require "test_helper"
require "support/app_oauth_test_helper"

# A person's OAuth app token drives rhythms in any enabled account where they
# are a confirmed member. A rhythm's own account decides authority; account_id
# only narrows.
class Api::V1::RhythmsOauthTest < ActionDispatch::IntegrationTest

  include AppOauthTestHelper

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:existing_user)
    @home = accounts(:existing_user_account)
    @team = accounts(:team_account)
    @user.update!(default_account_id: @home.id)
    @client = create_app_client
    @tokens = sign_in_device
    @headers = bearer(@tokens)
    @resident = agents(:other_account_agent)
    @attributes = {
      title: "Weekly reflection", opening: "Anything worth bringing forward?",
      cadence: "weekly", weekday: 1, time_of_day: "09:00", timezone: "Madrid", append_date: true
    }
    @rhythm = Rhythm.create!(@attributes.merge(account: @team, creator: @user, agents: [ @resident ]))
  end

  test "manages a rhythm in the person's second account without account_id" do
    get api_v1_rhythm_path(@rhythm), headers: @headers
    assert_response :ok
    assert response.parsed_body.dig("rhythm", "can_manage")

    patch api_v1_rhythm_path(@rhythm), params: { rhythm: { title: "Renamed" } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal "Renamed", @rhythm.reload.title

    post pause_api_v1_rhythm_path(@rhythm), params: { reason: "Away" }, headers: @headers, as: :json
    assert_response :ok
    assert_equal [ [ "human", @user.id ] ], @rhythm.open_holds.pluck(:kind, :user_id)
    post resume_api_v1_rhythm_path(@rhythm), headers: @headers
    assert_response :ok
    assert_not @rhythm.reload.held?

    # The web's rhythm pages write no audit rows; the API mirrors that.
    assert_no_difference "AuditLog.count" do
      post start_api_v1_rhythm_path(@rhythm), params: { request_key: "oauth-1" }, headers: @headers, as: :json
    end
    assert_response :created
    assert_equal @team, @rhythm.occurrences.sole.chat.account
  end

  test "account-level actions use the named account, or the default" do
    get api_v1_rhythms_path, headers: @headers
    assert_response :ok
    assert_empty response.parsed_body["rhythms"]
    get api_v1_rhythms_path, params: { account_id: @team.to_param }, headers: @headers
    assert_response :ok
    assert_equal [ @rhythm.to_param ], response.parsed_body["rhythms"].pluck("id")

    assert_difference "Rhythm.where(account: @team).count", 1 do
      post api_v1_rhythms_path, params: { account_id: @team.to_param, rhythm: @attributes.merge(resident_ids: [ @resident.to_param ]) },
        headers: @headers, as: :json
    end
    assert_response :created
    assert_equal @user, Rhythm.order(:id).last.creator
  end

  test "account_id naming another of the person's accounts is not found" do
    [ @home, accounts(:another_team) ].each do |account|
      get api_v1_rhythm_path(@rhythm), params: { account_id: account.to_param }, headers: @headers
      assert_response :not_found
      patch api_v1_rhythm_path(@rhythm), params: { account_id: account.to_param, rhythm: { title: "Nope" } },
        headers: @headers, as: :json
      assert_response :not_found
    end
    assert_equal "Weekly reflection", @rhythm.reload.title
  end

  test "a disabled account is not found" do
    @team.update_column(:disabled_at, Time.current)
    patch api_v1_rhythm_path(@rhythm), params: { rhythm: { title: "Nope" } }, headers: @headers, as: :json
    assert_response :not_found
    post pause_api_v1_rhythm_path(@rhythm), headers: @headers
    assert_response :not_found
    get api_v1_rhythms_path, params: { account_id: @team.to_param }, headers: @headers
    assert_response :not_found
    assert_equal "Weekly reflection", @rhythm.reload.title
    assert_not @rhythm.held?
  end

  test "a departed member is not found" do
    Membership.where(account: @team, user: @user).destroy_all
    patch api_v1_rhythm_path(@rhythm), params: { rhythm: { title: "Nope" } }, headers: @headers, as: :json
    assert_response :not_found
    delete api_v1_rhythm_path(@rhythm), headers: @headers
    assert_response :not_found
    assert_equal "Weekly reflection", @rhythm.reload.title
  end

  test "a resident key cannot use the person's controls" do
    key = ApiKey.generate_for(users(:user_1), name: "Resident", agent: @resident)
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    assert_no_difference "RhythmOccurrence.count" do
      post start_api_v1_rhythm_path(@rhythm), params: { request_key: "r" }, headers: headers, as: :json
    end
    assert_response :forbidden
    patch api_v1_rhythm_path(@rhythm), params: { rhythm: { title: "Mine" } }, headers: headers, as: :json
    assert_response :forbidden
    assert_equal "Weekly reflection", @rhythm.reload.title
  end

end
