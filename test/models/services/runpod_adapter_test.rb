require "test_helper"
require "webmock/minitest"

class Services::RunpodAdapterTest < ActiveSupport::TestCase

  setup do
    @adapter = Services::RunpodAdapter.new(Services::Definition.fetch("runpod"))
  end

  def stub_account(status: 200, body:, content_type: "application/json")
    stub_request(:get, "https://api.runpod.io/v2/account")
      .with(headers: { "Authorization" => "Bearer rp_secret" })
      .to_return(status: status, body: body.is_a?(String) ? body : body.to_json, headers: { "Content-Type" => content_type })
  end

  def connect(key = "rp_secret")
    @adapter.connection_attributes(credentials: { "api_key" => key }, user: users(:user_1))
  end

  test "builds a static credential connection from the key's account" do
    stub_account(body: { "id" => "user_2abc", "email" => "daniel@example.com" })

    result = connect(" rp_secret ")

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

  test "uses the account id when RunPod has no email on file" do
    stub_account(body: { "id" => "user_2abc", "email" => nil })

    assert_equal "user_2abc", connect[:external_identity]
  end

  test "refuses a key RunPod rejects" do
    stub_account(status: 401, body: { "detail" => "Subject token is invalid or expired", "status" => 401, "title" => "Unauthorized" },
                 content_type: "application/problem+json")

    error = assert_raises(Services::RunpodAdapter::Error) { connect }
    assert_equal "RunPod rejected this API key", error.message
  end

  test "says a valid key lacks account access, without echoing RunPod's error" do
    stub_account(status: 403, body: { "detail" => "raw provider detail", "status" => 403, "title" => "Forbidden" },
                 content_type: "application/problem+json")

    error = assert_raises(Services::RunpodAdapter::Error) { connect }
    assert_match "can't read the account", error.message
    assert_no_match "raw provider detail", error.message
  end

  test "refuses an answer with no account id" do
    stub_account(body: { "email" => "daniel@example.com" })
    assert_raises(Services::RunpodAdapter::Error) { connect }
  end

  test "refuses an answer that is not an object" do
    stub_account(body: [ { "id" => "user_2abc" } ])
    assert_raises(Services::RunpodAdapter::Error) { connect }
  end

  test "refuses invalid JSON" do
    stub_account(body: "<html>oops</html>", content_type: "text/html")
    error = assert_raises(Services::RunpodAdapter::Error) { connect }
    assert_equal "RunPod returned invalid JSON", error.message
  end

  test "requires a key" do
    error = assert_raises(Services::RunpodAdapter::Error) { connect("  ") }
    assert_equal "RunPod API key is required", error.message
  end

end
