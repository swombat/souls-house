require "test_helper"

class Services::TailscaleAdapterTest < ActiveSupport::TestCase

  setup do
    @adapter = Services::TailscaleAdapter.new(Services::Definition.fetch("tailscale"))
  end

  test "with nothing pasted, builds a sign-in connection that carries no secret" do
    result = @adapter.connection_attributes(credentials: {}, user: users(:user_1))

    assert_equal "none", result[:credential_kind]
    assert_equal({}, result[:credential_payload])
    assert_equal "sign_in", result.dig(:credential_metadata, "join")
    assert_equal [], result.dig(:credential_metadata, "hosts")
    assert_equal "Tailnet", result[:label]
    assert_equal result[:credential_fingerprint],
                 @adapter.connection_attributes(credentials: { "hosts" => "" }, user: users(:user_1))[:credential_fingerprint],
                 "one sign-in connection per account"
  end

  test "still accepts an auth key with parsed hosts, for tagged tailnets" do
    result = @adapter.connection_attributes(
      credentials: {
        "auth_key" => " tskey-auth-kAbc123CNTRL-secretpart ",
        "hosts" => "dell=daniel@dell, Mac = danieltenner@danbook.tail1234.ts.net\nnas=100.101.102.103"
      },
      user: users(:user_1)
    )

    assert_equal "token", result[:credential_kind]
    assert_equal "auth_key", result.dig(:credential_metadata, "join")
    assert_equal "tskey-auth-kAbc123CNTRL-secretpart", result.dig(:credential_payload, "auth_key")
    assert_equal [
      { "alias" => "dell", "user" => "daniel", "machine" => "dell" },
      { "alias" => "mac", "user" => "danieltenner", "machine" => "danbook.tail1234.ts.net" },
      { "alias" => "nas", "machine" => "100.101.102.103" }
    ], result.dig(:credential_metadata, "hosts")
    assert_equal "Tailnet: dell, mac, nas", result[:label]
    assert result[:credential_fingerprint].present?
    assert_not_includes result[:credential_metadata].to_json, "secretpart"
  end

  test "allows a connection without hosts" do
    result = @adapter.connection_attributes(credentials: { "auth_key" => "tskey-auth-abc" }, user: users(:user_1))

    assert_equal [], result.dig(:credential_metadata, "hosts")
    assert_equal "Tailnet", result[:label]
  end

  test "rejects keys that are not auth keys" do
    [ "tskey-api-abc", "tskey-client-abc", "tskey-auth-abc def" ].each do |key|
      assert_raises(Services::TailscaleAdapter::Error, key) do
        @adapter.connection_attributes(credentials: { "auth_key" => key }, user: users(:user_1))
      end
    end
  end

  test "rejects malformed and duplicate host entries" do
    [
      "dell",
      "dell=daniel@",
      "dell=bad user@dell",
      "-x=daniel@dell",
      "dell=daniel@dell;rm",
      "dell=-oProxyCommand=evil",
      "dell=daniel@dell, DELL=daniel@other"
    ].each do |hosts|
      assert_raises(Services::TailscaleAdapter::Error, hosts) do
        @adapter.connection_attributes(credentials: { "auth_key" => "tskey-auth-abc", "hosts" => hosts }, user: users(:user_1))
      end
    end
  end

  test "is registered as a static credentials provider" do
    definition = Services::Definition.fetch("tailscale")

    assert_equal "credentials", definition.connection_method
    assert_equal "static", definition.credential_strategy
    assert_equal [], definition.credential_fields, "nothing to paste: residents join by signing in"
  end

end
