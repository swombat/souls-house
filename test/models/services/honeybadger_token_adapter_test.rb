require "test_helper"

class Services::HoneybadgerTokenAdapterTest < ActiveSupport::TestCase

  setup do
    @adapter = Services::HoneybadgerTokenAdapter.new(Services::Definition.fetch("honeybadger"))
    @accounts = {
      "results" => [
        { "id" => "Me3upk", "email" => "daniel@example.com", "name" => "souls.house" },
        { "id" => "9bYfrm", "email" => "daniel@example.com", "name" => "Personal" }
      ]
    }
  end

  test "builds a static credential connection from the token's accounts" do
    calls = []
    @adapter.stub :get_json, ->(origin, path, token) {
      calls << [ origin, path, token ]
      @accounts
    } do
      result = @adapter.connection_attributes(credentials: { "auth_token" => " hb_secret " }, user: users(:user_1))

      assert_equal [ [ "https://app.honeybadger.io", "/v2/accounts", "hb_secret" ] ], calls
      assert_equal "9bYfrm,Me3upk", result[:external_subject_id]
      assert_equal "daniel@example.com", result[:external_identity]
      assert_equal "Honeybadger (souls.house, Personal)", result[:label]
      assert_equal "token", result[:credential_kind]
      assert_equal({ "auth_token" => "hb_secret" }, result[:credential_payload])
      assert_equal "us", result.dig(:credential_metadata, "region")
      assert_equal "https://app.honeybadger.io/v2", result.dig(:credential_metadata, "api_base")
      assert_equal "static", result.dig(:credential_metadata, "credential_strategy")
      assert_not_includes result[:credential_metadata].values.join(" "), "hb_secret"
      assert_not_includes result[:credential_fingerprint], "hb_secret"
    end
  end

  test "falls through to the EU region when the US rejects the token" do
    @adapter.stub :get_json, ->(origin, _path, _token) {
      raise Services::HoneybadgerTokenAdapter::Rejected, "no" if origin == "https://app.honeybadger.io"
      @accounts
    } do
      result = @adapter.connection_attributes(credentials: { "auth_token" => "hb_secret" }, user: users(:user_1))

      assert_equal "eu", result.dig(:credential_metadata, "region")
      assert_equal "https://eu-app.honeybadger.io/v2", result.dig(:credential_metadata, "api_base")
    end
  end

  test "refuses a token both regions reject" do
    @adapter.stub :get_json, ->(*) { raise Services::HoneybadgerTokenAdapter::Rejected, "no" } do
      error = assert_raises(Services::HoneybadgerTokenAdapter::Error) do
        @adapter.connection_attributes(credentials: { "auth_token" => "hb_secret" }, user: users(:user_1))
      end

      assert_match "tried the US and EU regions", error.message
    end
  end

  test "does not try the EU region when the US fails for another reason" do
    calls = 0
    @adapter.stub :get_json, ->(*) {
      calls += 1
      raise Services::HoneybadgerTokenAdapter::Error, "Honeybadger validation failed (500)"
    } do
      error = assert_raises(Services::HoneybadgerTokenAdapter::Error) do
        @adapter.connection_attributes(credentials: { "auth_token" => "hb_secret" }, user: users(:user_1))
      end

      assert_equal "Honeybadger validation failed (500)", error.message
      assert_equal 1, calls
    end
  end

  test "refuses a token with no accounts" do
    @adapter.stub :get_json, ->(*) { { "results" => [] } } do
      error = assert_raises(Services::HoneybadgerTokenAdapter::Error) do
        @adapter.connection_attributes(credentials: { "auth_token" => "hb_secret" }, user: users(:user_1))
      end

      assert_equal "This token has no Honeybadger accounts", error.message
    end
  end

  test "requires a token" do
    error = assert_raises(Services::HoneybadgerTokenAdapter::Error) do
      @adapter.connection_attributes(credentials: {}, user: users(:user_1))
    end

    assert_equal "Honeybadger personal auth token is required", error.message
  end

end
