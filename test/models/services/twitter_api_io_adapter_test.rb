require "test_helper"
require "webmock/minitest"

class Services::TwitterApiIoAdapterTest < ActiveSupport::TestCase

  INFO = "https://api.twitterapi.io/oapi/my/info".freeze

  setup do
    @adapter = Services::TwitterApiIoAdapter.new(Services::Definition.fetch("twitterapi_io"))
  end

  test "proves the key on the free info call and keeps only what is needed" do
    info = stub_request(:get, INFO).with(headers: { "X-API-Key" => "tw-key" })
      .to_return(status: 200, body: { recharge_credits: 1_892_815, total_bonus_credits: 0 }.to_json)

    result = @adapter.connection_attributes(credentials: { "api_key" => " tw-key \n" }, user: users(:user_1))

    assert_requested info
    assert_equal({ "api_key" => "tw-key" }, result[:credential_payload])
    assert_equal "api_key", result[:credential_kind]
    assert_equal 1_892_815, result.dig(:credential_metadata, "credits_at_connect")
    assert_match "cannot post", result.dig(:credential_metadata, "authority_summary")
    assert_not_includes result[:credential_metadata].values.join(" "), "tw-key"
    assert_not_includes result[:credential_fingerprint], "tw-key"
  end

  test "a refused key is not connected, and the error never carries the key or the body" do
    stub_request(:get, INFO).to_return(status: 401, body: { error: "bad key tw-bad" }.to_json)
    error = assert_raises(Services::AdapterError) do
      @adapter.connection_attributes(credentials: { "api_key" => "tw-bad" }, user: users(:user_1))
    end
    assert_equal "TwitterAPI.io rejected this key (401)", error.message
  end

  test "an unreachable or failing provider is not taken as proof" do
    stub_request(:get, INFO).to_return(status: 503)
    assert_raises(Services::AdapterError) { @adapter.connection_attributes(credentials: { "api_key" => "k" }, user: users(:user_1)) }
    stub_request(:get, INFO).to_timeout
    assert_raises(Services::AdapterError) { @adapter.connection_attributes(credentials: { "api_key" => "k" }, user: users(:user_1)) }
  end

  test "a key is required, and only an account can hold one" do
    assert_raises(Services::AdapterError) { @adapter.connection_attributes(credentials: { "api_key" => " " }, user: users(:user_1)) }
    definition = Services::Definition.fetch("twitterapi_io")
    assert definition.supports_management_scope?("account_managed")
    assert_not definition.supports_management_scope?("personal")
  end

end
