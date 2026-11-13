require "test_helper"

class Api::V1::PostizControllerTest < ActionDispatch::IntegrationTest
  setup do
    @agent = agents(:research_assistant)
    @user = users(:user_1)
    @key = ApiKey.generate_for(@user, name: "Postiz", agent: @agent)
    @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
    @connection = @agent.account.service_connections.create!(
      connected_by_user: @user, provider: "postiz", management_scope: "personal",
      credential_kind: "token", status: "connected",
      credential_payload_hash: { "api_token" => "house-secret", "api_base" => Services::PostizAdapter::DEFAULT_BASE },
      credential_metadata: { "credential_strategy" => "postiz_proxy" }
    )
    @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    @channels = api_v1_service_connection_postiz_channels_url(@connection.public_id)
    @drafts = api_v1_service_connection_postiz_drafts_url(@connection.public_id)
  end

  test "disabled grants and disconnected connections cannot call Postiz" do
    @access.update!(enabled: false)
    get @channels, headers: @headers
    assert_response :not_found
    @access.update!(enabled: true)
    @connection.update!(status: "revoked")
    get @channels, headers: @headers
    assert_response :conflict
  end

  test "human API keys cannot use either endpoint" do
    key = ApiKey.generate_for(@user, name: "Human Postiz")
    headers = { "Authorization" => "Bearer #{key.raw_token}" }
    get @channels, headers: headers
    assert_response :forbidden
    post @drafts, params: { channel_id: "c1", content: "Hello" }, headers: headers, as: :json
    assert_response :forbidden
  end

  test "other residents without a grant cannot use either endpoint across accounts" do
    %i[code_reviewer other_account_agent].each do |fixture|
      agent = agents(fixture)
      user = agent.account.users.first
      key = ApiKey.generate_for(user, name: "No Postiz grant", agent: agent)
      headers = { "Authorization" => "Bearer #{key.raw_token}" }
      get @channels, headers: headers
      assert_response :not_found
      post @drafts, params: { channel_id: "c1", content: "Hello" }, headers: headers, as: :json
      assert_response :not_found
    end
  end

  test "draft rejects extra provider authority" do
    %w[type date posts settings image].each do |field|
      post @drafts, params: { channel_id: "c1", content: "Hello", field => "publish" },
        headers: @headers, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "manifest and browser props never contain the token" do
    manifest = @connection.runtime_credentials(agent: @agent)
    assert_equal %w[channels_endpoint drafts_endpoint], manifest.keys
    assert_not_includes manifest.to_json, "house-secret"
    assert_not_includes @connection.as_connection_json(current_user: @user).to_json, "house-secret"
    assert_includes @connection.runtime_entry(agent: @agent)["warnings"].last, "house-enforced"
  end

  test "granted resident can list channels and create a text draft" do
    adapter = Object.new
    adapter.define_singleton_method(:list_channels) { |_connection| [ { id: "c1" } ] }
    adapter.define_singleton_method(:create_draft) do |_connection, channel_id:, content:|
      raise "Wrong input" unless channel_id == "c1" && content == "Hello"
      [ { id: "draft1" } ]
    end
    Services::Definition.fetch("postiz").stub(:adapter, adapter) do
      get @channels, headers: @headers
      assert_response :ok
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_equal "c1", response.parsed_body.first["id"]
      post @drafts, params: { channel_id: "c1", content: "Hello" }, headers: @headers, as: :json
      assert_response :ok
      assert_equal "draft1", response.parsed_body.first["id"]
    end
  end

  test "publishing deletion and upload routes do not exist" do
    %w[publish schedule delete upload].each do |operation|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(
          "/api/v1/service_connections/#{@connection.public_id}/postiz/#{operation}", method: :post
        )
      end
    end
  end
end
