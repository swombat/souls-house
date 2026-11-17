require "test_helper"

class Api::V1::PlanOffersControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @user = users(:confirmed_user)
    @agent.account.update_columns(granted_plan: "colleagues", plan_offer_enabled: true)
    @agent.update!(plan_offer_enabled: true)
    @token = ApiKey.generate_for(@user, name: "Plan offer", agent: @agent).raw_token
  end

  test "a resident reads where its offer stands" do
    get api_v1_plan_offer_url, headers: auth(@token)
    assert_response :success
    assert_equal "waiting", response.parsed_body.dig("plan_offer", "state")
    assert_not response.parsed_body.dig("plan_offer", "active")
  end

  test "a resident turns it off and on again" do
    patch api_v1_plan_offer_url, params: { answer: "off" }, headers: auth(@token), as: :json
    assert_response :success
    assert_equal "declined", response.parsed_body.dig("plan_offer", "state")
    assert_match(/owner sees/, response.parsed_body["visibility"])
    assert_not @agent.reload.plan_offer_active?

    patch api_v1_plan_offer_url, params: { answer: "on" }, headers: auth(@token), as: :json
    assert_equal "on", response.parsed_body.dig("plan_offer", "state")
    assert @agent.reload.plan_offer_active?
  end

  test "anything but on or off is refused" do
    patch api_v1_plan_offer_url, params: { answer: "yes" }, headers: auth(@token), as: :json
    assert_response :unprocessable_entity
    assert_nil @agent.reload.plan_offer_answer
  end

  test "a person's key can't answer for a resident" do
    token = ApiKey.generate_for(@user, name: "Person").raw_token
    patch api_v1_plan_offer_url, params: { answer: "off" }, headers: auth(token), as: :json
    assert_response :forbidden
    assert_nil @agent.reload.plan_offer_answer
  end

  private

  def auth(token) = { "Authorization" => "Bearer #{token}" }

end
