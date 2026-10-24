require "test_helper"

class Api::V1::CompanionEnrollmentTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:personal_account)
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    # No real resident is used, and no runtime/HTTP work is invoked.
    @human_key = ApiKey.generate_for(@user, name: "Synthetic owner", account: @account)
    @resident_key = ApiKey.generate_for(@user, name: "Synthetic resident", agent: @agent)
  end

  test "owner grants resident mints and public device enrolls then rotates session credential" do
    grant_id = create_grant
    assert_equal [ "authority_warnings", "expires_at", "id" ], response.parsed_body.keys.sort
    assert_empty response.parsed_body.fetch("authority_warnings")
    post "/api/v1/companion_enrollment_grants/#{grant_id}/token", headers: bearer(@resident_key.raw_token)
    assert_response :created
    token = response.parsed_body.fetch("enrollment_token")
    assert_equal "no-store", response.headers["Cache-Control"]
    post "/api/v1/companion/enroll", params: { enrollment_token: token, device_request_id: "request-1" }, as: :json
    assert_response :created
    enrollment_response = response.parsed_body
    credential = enrollment_response.fetch("device_credential")
    assert_equal 1, response.parsed_body["revision"]
    post "/api/v1/companion/session", params: { request_id: "session-1" }, headers: bearer(credential), as: :json
    assert_response :created
    session = response.parsed_body
    assert session["cable_ticket"]
    assert_not_equal credential, session["device_credential"]
    post "/api/v1/companion/session", params: { request_id: "session-1" }, headers: bearer(credential), as: :json
    assert_response :created
    assert_equal session, response.parsed_body
    post "/api/v1/companion/enroll", params: { enrollment_token: token, device_request_id: "request-1" }, as: :json
    assert_response :created
    assert_equal enrollment_response, response.parsed_body
    get "/api/v1/me", headers: bearer(session["device_credential"])
    assert_response :unauthorized
  end

  test "human grant creation warns that home volume write is deferred execution without an execute grant" do
    post_grant(policy: { residents: [ { id: @agent.obfuscated_id,
      volumes: [ { volume: "opaque-volume", access: "write" } ], execute: false } ] })
    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    warnings = response.parsed_body.fetch("authority_warnings")
    assert_equal 1, warnings.size
    assert_match(/volume containing the service user's home/, warnings.sole)
    assert_match(/deferred arbitrary code execution as that user/, warnings.sole)
    assert_match(/\.bashrc/, warnings.sole)
    assert_match(/even without an execute grant/, warnings.sole)
    assert_equal false, CompanionEnrollmentGrant.sole.policy.fetch("residents").sole.fetch("execute")
  end

  test "human execute-only grant creation warns that execution can rewrite the local ceiling" do
    post_grant(policy: { residents: [ { id: @agent.obfuscated_id, volumes: [], execute: true } ] })
    assert_response :created
    warnings = response.parsed_body.fetch("authority_warnings")
    assert_equal 1, warnings.size
    assert_match(/service user's OS authority/, warnings.sole)
    assert_match(/rewrite state\.json, including the local ceiling/, warnings.sole)
    assert_match(/not a sandbox/, warnings.sole)
    assert_match(/not an enforceable limit against an execute-granted actor/, warnings.sole)
  end

  test "human grant creation includes both warnings for permissions held by different residents" do
    post_grant(policy: { residents: [
      { id: @agent.obfuscated_id, volumes: [], execute: true },
      { id: agents(:code_reviewer).obfuscated_id,
        volumes: [ { volume: "opaque-volume", access: "write" } ], execute: false }
    ] })
    assert_response :created
    warnings = response.parsed_body.fetch("authority_warnings")
    assert_equal 2, warnings.size
    assert_match(/deferred arbitrary code execution/, warnings.first)
    assert_match(/rewrite state\.json/, warnings.last)
  end

  test "resident and ordinary account member cannot approve enrollment" do
    post "/api/v1/companion_enrollment_grants", params: grant_params, headers: bearer(@resident_key.raw_token), as: :json
    assert_response :forbidden
    key = ApiKey.generate_for(users(:existing_user), name: "Synthetic member", account: accounts(:team_account))
    post "/api/v1/companion_enrollment_grants", params: grant_params, headers: bearer(key.raw_token), as: :json
    assert_response :forbidden
    assert_equal 0, CompanionEnrollmentGrant.count
  end

  test "unconfirmed departed and disabled account human credentials cannot approve" do
    membership = memberships(:daniel_personal)
    membership.update_columns(confirmed_at: nil)
    post_grant
    assert_response :not_found
    membership.update_columns(confirmed_at: Time.current)
    @account.update_columns(disabled_at: Time.current)
    post_grant
    assert_response :not_found
    assert_equal 0, CompanionEnrollmentGrant.count
  end

  test "human wrong resident and foreign resident cannot mint" do
    id = create_grant
    post "/api/v1/companion_enrollment_grants/#{id}/token", headers: bearer(@human_key.raw_token)
    assert_response :forbidden
    [ agents(:code_reviewer), agents(:other_account_agent) ].each do |agent|
      key = ApiKey.generate_for(@user, name: "Synthetic other resident", agent: agent)
      post "/api/v1/companion_enrollment_grants/#{id}/token", headers: bearer(key.raw_token)
      assert_response :not_found
    end
    assert_nil CompanionEnrollmentGrant.sole.token_digest
  end

  test "foreign minting agent and foreign policy residents are refused" do
    post_grant(minting_agent_id: agents(:other_account_agent).obfuscated_id)
    assert_response :not_found
    post_grant(policy: { residents: [ { id: agents(:other_account_agent).obfuscated_id, volumes: [], execute: false } ] })
    assert_response :unprocessable_entity
    assert_equal 0, CompanionEnrollmentGrant.count
  end

  test "malformed grant shapes are client errors and never create grants" do
    [
      { name: [] }, { device_request_id: [] }, { expires_at: [] },
      { expires_at: "tomorrow" }, { policy: [] }, { minting_agent_id: @agent.id.to_s }
    ].each do |invalid|
      post_grant(invalid)
      assert_response :unprocessable_entity
    end
    assert_equal 0, CompanionEnrollmentGrant.count
  end

  test "only enrollment is public and no human or resident key authenticates a device session" do
    post "/api/v1/companion_enrollment_grants", params: grant_params, as: :json
    assert_response :unauthorized
    post "/api/v1/companion/enroll", params: { enrollment_token: [], device_request_id: "request-1" }, as: :json
    assert_response :unauthorized
    [ nil, @human_key.raw_token, @resident_key.raw_token ].each do |value|
      post "/api/v1/companion/session", params: { request_id: "session-1" }, headers: bearer(value), as: :json
      assert_response :unauthorized
    end
  end

  private

  def bearer(value)
    { "Authorization" => "Bearer #{value}" }
  end

  def grant_params
    { minting_agent_id: @agent.obfuscated_id, name: "Synthetic companion",
      device_request_id: "request-1", expires_at: 1.hour.from_now.iso8601,
      policy: { residents: [ { id: @agent.obfuscated_id,
        volumes: [ { volume: "opaque-volume", access: "read" } ], execute: false } ] } }
  end

  def post_grant(overrides = {})
    post "/api/v1/companion_enrollment_grants", params: grant_params.merge(overrides),
      headers: bearer(@human_key.raw_token), as: :json
  end

  def create_grant
    post_grant
    assert_response :created
    response.parsed_body.fetch("id")
  end

end
