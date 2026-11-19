require "test_helper"

class Accounts::CompanionPairingsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @owner = users(:user_1)
    @pairing, @code, @secret = CompanionPairing.open!(name: "Paulina's Mac", device_request_id: "pair-1",
      volumes: [ { "volume" => "darwin-volume:main", "label" => "Main disk", "access" => "read" } ])
  end

  test "an owner looks up the code, approves, and the computer enrolls with what it collects" do
    sign_in @owner
    post lookup_account_companion_pairings_path(@account), params: { code: @code.downcase }, as: :json
    assert_response :success
    assert_equal "Paulina's Mac", response.parsed_body["name"]
    assert_equal [ "Main disk" ], response.parsed_body["volumes"].map { |v| v["label"] }
    assert_includes response.parsed_body["residents"].map { |r| r["id"] }, @agent.to_param

    post account_companion_pairings_path(@account),
      params: { code: @code, resident_ids: [ @agent.to_param ], accesses: { "darwin-volume:main" => "read" } }
    assert_redirected_to account_companion_devices_path(@account)
    assert_match(/being added/, flash[:notice])

    post claim_api_v1_companion_pairing_path(@pairing.to_param), params: { poll_secret: @secret }, as: :json
    assert_response :ok
    token = response.parsed_body["enrollment_token"]
    post api_v1_companion_enroll_path, params: { enrollment_token: token, device_request_id: "pair-1" }, as: :json
    assert_response :created
    assert_equal [ "Paulina's Mac" ], CompanionDevice.where(account: @account).pluck(:name)
  end

  test "an unknown code says so, and a member who isn't an admin can't look up or approve" do
    sign_in @owner
    post lookup_account_companion_pairings_path(@account), params: { code: "ZZZZ-ZZZZ" }, as: :json
    assert_response :not_found

    team = agents(:other_account_agent).account
    sign_in users(:existing_user)
    post lookup_account_companion_pairings_path(team), params: { code: @code }, as: :json
    assert_response :forbidden
    post account_companion_pairings_path(team),
      params: { code: @code, resident_ids: [ agents(:other_account_agent).to_param ], accesses: { "darwin-volume:main" => "read" } }
    assert_redirected_to account_companion_devices_path(team)
    assert_nil @pairing.reload.approved_at
  end

  test "a resident from another account is refused" do
    sign_in @owner
    post account_companion_pairings_path(@account),
      params: { code: @code, resident_ids: [ agents(:other_account_agent).to_param ], accesses: { "darwin-volume:main" => "read" } }
    assert_redirected_to account_companion_devices_path(@account)
    assert_nil @pairing.reload.approved_at
  end

end
