require "test_helper"

class Api::V1::VisitsControllerTest < ActionDispatch::IntegrationTest

  include WebMock::API

  teardown { WebMock.reset! }

  setup do
    @agent = agents(:research_assistant)
    @resident_key = ApiKey.generate_for(@agent.account.owner, name: "resident", agent: @agent)
    @owner_key = ApiKey.generate_for(@agent.account.owner, name: "owner")
    @visit = @agent.visits.create!(
      visited_origin: "https://other.souls.house",
      visited_house_name: "Other House",
      visited_account_name: "Nexus",
      local_name: "Reed",
      visit_token: "vst_secret_proxy_token"
    )
    @public_client = Visits::Client.new(resolver: ->(_) { [ "93.184.216.34" ] }, allow_http: false)
  end

  test "refuses non-resident API keys" do
    get "/api/v1/visits", headers: auth(@owner_key)
    assert_response :forbidden
  end

  test "lists visits without exposing visit_token" do
    get "/api/v1/visits", headers: auth(@resident_key)
    assert_response :success
    assert_equal 1, response.parsed_body["visits"].length
    refute_includes response.body, "vst_secret_proxy_token"
  end

  test "proxies transcript read and message post with the encrypted visit token" do
    stub_request(:get, "https://other.souls.house/api/v1/visit/conversations/conv1?wake_id=w1")
      .with(headers: { "Authorization" => "Bearer vst_secret_proxy_token" })
      .to_return(status: 200, body: { messages: [ { id: "m1", content: "hello" } ] }.to_json, headers: { "Content-Type" => "application/json" })

    stub_request(:post, "https://other.souls.house/api/v1/visit/conversations/conv1/messages")
      .with(headers: { "Authorization" => "Bearer vst_secret_proxy_token" })
      .to_return(status: 201, body: { message: { id: "m2", content: "hi there" } }.to_json, headers: { "Content-Type" => "application/json" })

    Visits::Client.stub(:new, @public_client) do
      get "/api/v1/visits/#{@visit.to_param}/conversations/conv1?wake_id=w1", headers: auth(@resident_key)
      assert_response :success
      assert_equal "hello", response.parsed_body.dig("messages", 0, "content")

      post "/api/v1/visits/#{@visit.to_param}/conversations/conv1/messages",
        params: { content: "hi there" }, as: :json, headers: auth(@resident_key)
      assert_response :created
      assert_equal "hi there", response.parsed_body.dig("message", "content")
    end
  end

  test "marks visit revoked when remote rejects token with 401" do
    stub_request(:get, "https://other.souls.house/api/v1/visit/conversations/conv1")
      .to_return(status: 401, body: { error: "revoked" }.to_json, headers: { "Content-Type" => "application/json" })

    Visits::Client.stub(:new, @public_client) do
      get "/api/v1/visits/#{@visit.to_param}/conversations/conv1", headers: auth(@resident_key)
      assert_response :unauthorized
    end
    assert_equal "revoked", @visit.reload.status
  end

  private

  def auth(key)
    { "Authorization" => "Bearer #{key.raw_token}" }
  end

end
