require "test_helper"
require "webmock/minitest"

class Services::RunpodAdapterTest < ActiveSupport::TestCase

  setup do
    @adapter = Services::RunpodAdapter.new(Services::Definition.fetch("runpod"))
  end

  def stub_graphql(status: 200, body:)
    stub_request(:post, "https://api.runpod.io/graphql")
      .with(headers: { "Authorization" => "Bearer rp_secret" }, body: { query: "query { myself { id email } }" }.to_json)
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  test "builds a static credential connection from the key's account" do
    stub_graphql(body: { "data" => { "myself" => { "id" => "user_2abc", "email" => "daniel@example.com" } } })

    result = @adapter.connection_attributes(credentials: { "api_key" => " rp_secret " }, user: users(:user_1))

    assert_equal "user_2abc", result[:external_subject_id]
    assert_equal "daniel@example.com", result[:external_identity]
    assert_equal "RunPod (daniel@example.com)", result[:label]
    assert_equal "token", result[:credential_kind]
    assert_equal({ "api_key" => "rp_secret" }, result[:credential_payload])
    assert_equal "https://api.runpod.io/v2", result.dig(:credential_metadata, "api_base")
    assert_equal "static", result.dig(:credential_metadata, "credential_strategy")
    assert_not_includes result[:credential_metadata].values.join(" "), "rp_secret"
    assert_not_includes result[:credential_fingerprint], "rp_secret"
  end

  test "falls back to the account id when RunPod gives no email" do
    stub_graphql(body: { "data" => { "myself" => { "id" => "user_2abc", "email" => nil } } })

    result = @adapter.connection_attributes(credentials: { "api_key" => "rp_secret" }, user: users(:user_1))

    assert_equal "user_2abc", result[:external_identity]
  end

  test "refuses a key RunPod rejects" do
    stub_graphql(status: 401, body: { "error" => {} })

    error = assert_raises(Services::RunpodAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_key" => "rp_secret" }, user: users(:user_1))
    end
    assert_equal "RunPod rejected this API key", error.message
  end

  test "refuses a GraphQL error even on a 200" do
    stub_graphql(body: { "errors" => [ { "message" => "Unauthorized" } ], "data" => nil })

    error = assert_raises(Services::RunpodAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_key" => "rp_secret" }, user: users(:user_1))
    end
    assert_match "Unauthorized", error.message
  end

  test "refuses an answer with no account" do
    stub_graphql(body: { "data" => { "myself" => nil } })

    assert_raises(Services::RunpodAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_key" => "rp_secret" }, user: users(:user_1))
    end
  end

  test "requires a key" do
    error = assert_raises(Services::RunpodAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_key" => "  " }, user: users(:user_1))
    end
    assert_equal "RunPod API key is required", error.message
  end

end
