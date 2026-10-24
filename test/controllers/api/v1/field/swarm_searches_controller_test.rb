require "test_helper"
require "support/field_swarm_helpers"

# POST /api/v1/field/swarm_search and its Site Admin switch.
class Api::V1::Field::SwarmSearchesControllerTest < ActionDispatch::IntegrationTest

  include FieldSwarmHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @resident = agents(:research_assistant)
    @account = @resident.account
    key = ApiKey.generate_for(@user, name: "Swarm tests", agent: @resident)
    @headers = { "Authorization" => "Bearer #{key.raw_token}" }
    @note = tagged_note(@account, "Board call", "Bob said it was worth four million.")
    @reader = ->(**) { answer("extract_enough", extract: "Four million.", quotes: [ "worth four million" ]) }
  end

  def swarm(params)
    post api_v1_field_swarm_search_path, params: params, headers: @headers, as: :json
  end

  test "off by default: 403 with who to ask, and nothing is read or recorded" do
    assert_not @account.reload.field_swarm_enabled?
    with_reader(->(**) { flunk "no reader should run" }) { swarm(tag: "research", question: "Worth?") }
    assert_response :forbidden
    assert_match "site admin", response.parsed_body["error"]
    assert_equal 0, FieldSwarmSearch.count
  end

  test "on: items with verdicts, extracts and locators, and a summary with the cost" do
    @account.update!(field_swarm_enabled: true)
    with_reader(@reader) { swarm(tag: [ "research" ], grep: "(?i)bob", question: "What was it worth?") }
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    item = response.parsed_body["items"].sole
    assert_equal [ "note", @note.to_param, "extract_enough" ], item.values_at("kind", "id", "verdict")
    locator = item["locators"].sole
    assert_equal "worth four million", @note.content[locator["offset"], locator["length"]]
    summary = response.parsed_body["summary"]
    assert_equal 1, summary["matched_items"]
    assert_equal "0.000125", summary["cost_usd"]
    assert summary["complete"]
    assert_equal @resident, FieldSwarmSearch.sole.agent
  end

  test "bad input is 422; the daily limit is 429" do
    @account.update!(field_swarm_enabled: true)
    with_reader(@reader) do
      swarm(tag: "research")
      assert_response :unprocessable_entity
      swarm(question: "Worth?")
      assert_response :unprocessable_entity
      swarm(tag: "research", question: "Worth?", grep: "(")
      assert_response :unprocessable_entity
      swarm(tag: "research", question: { a: 1 })
      assert_response :unprocessable_entity

      FieldSwarm::MAX_SEARCHES_PER_ACCOUNT_PER_DAY.times do
        FieldSwarmSearch.create!(account: @account, question_chars: 1, model_id: FieldSwarm::MODEL, status: "complete")
      end
      swarm(tag: "research", question: "Worth?")
      assert_response :too_many_requests
    end
  end

  test "the switch is site-admin only and audited, and the admin page shows the costs" do
    sign_in(users(:regular_user))
    patch field_swarm_admin_account_path(@account), params: { account: { field_swarm_enabled: true } }
    assert_not @account.reload.field_swarm_enabled?

    sign_out if respond_to?(:sign_out)
    sign_in(users(:site_admin_user))
    assert_difference -> { AuditLog.count }, 1 do
      patch field_swarm_admin_account_path(@account), params: { account: { field_swarm_enabled: true } }
    end
    assert @account.reload.field_swarm_enabled?

    FieldSwarmSearch.create!(account: @account, question_chars: 5, model_id: FieldSwarm::MODEL, status: "complete",
      completed_reads: 4, cost_usd: BigDecimal("0.002"))
    get admin_accounts_path(account_id: @account.to_param)
    assert_response :success
    assert_includes response.body, "cost_per_search_usd"
    assert_includes response.body, "0.002"
  end

end
