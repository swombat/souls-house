require "test_helper"

class Agents::VisitsControllerTest < ActionDispatch::IntegrationTest

  include WebMock::API

  teardown { WebMock.reset! }

  setup do
    @account = accounts(:team_account)
    @agent = agents(:other_account_agent)
    Setting.instance.update!(allow_agents: true)
    @public_client = Visits::Client.new(resolver: ->(_) { [ "93.184.216.34" ] }, allow_http: false)
  end

  test "owner previews and accepts a visitor invitation, storing an encrypted Visit" do
    sign_in(users(:user_1))
    stub_request(:get, "https://other.souls.house/api/v1/visit/invitations/vinv_12345678")
      .to_return(status: 200, body: {
        account: { name: "Nexus" },
        house: { name: "Nexus House", origin: "https://other.souls.house" },
        local_name: nil,
        expires_at: 1.day.from_now.iso8601,
        state: "open"
      }.to_json)
    stub_request(:post, "https://other.souls.house/api/v1/visit/invitations/vinv_12345678/accept")
      .to_return(status: 201, body: {
        visit_token: "visit_minted_secret",
        visit: {
          id: "adm1",
          account: { id: "acc1", name: "Nexus" },
          agent: { id: "ag1", name: "Reed (Grove)", colour: "teal", icon: "Leaf" },
          state: "current",
          seats: []
        }
      }.to_json)

    Visits::Client.stub(:new, @public_client) do
      post preview_account_agent_visits_path(@account, @agent),
        params: { invitation_url: "https://other.souls.house/api/v1/visit/invitations/vinv_12345678" }, as: :json
      assert_response :success
      assert_equal "Nexus", response.parsed_body.dig("preview", "account", "name")

      post account_agent_visits_path(@account, @agent),
        params: { origin: "https://other.souls.house", token: "vinv_12345678", local_name: "Reed (Grove)", visited_house_name: "Nexus House" }, as: :json
      assert_response :created
    end

    visit = @agent.visits.last
    assert_equal "https://other.souls.house", visit.visited_origin
    assert_equal "Nexus", visit.visited_account_name
    assert_equal "Nexus House", visit.visited_house_name
    assert_equal "Reed (Grove)", visit.local_name
    assert_equal "visit_minted_secret", visit.visit_token
    refute_includes response.body, "visit_minted_secret"
  end

  test "owner can leave an active visit" do
    sign_in(users(:user_1))
    visit = @agent.visits.create!(visited_origin: "https://other.souls.house", visit_token: "vst_leave_secret")
    stub_request(:delete, "https://other.souls.house/api/v1/visit").to_return(status: 200, body: "{}")

    Visits::Client.stub(:new, @public_client) do
      delete account_agent_visit_path(@account, @agent, visit), as: :json
      assert_response :success
    end
    assert_equal "ended", visit.reload.status
  end

end
