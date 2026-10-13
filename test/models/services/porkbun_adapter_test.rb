require "test_helper"
require "webmock/minitest"

class Services::PorkbunAdapterTest < ActiveSupport::TestCase

  API = "https://api.porkbun.com/api/json/v3".freeze

  setup do
    @adapter = Services::PorkbunAdapter.new(Services::Definition.fetch("porkbun"))
  end

  test "proves the key pair on /ping and labels the connection with the account's domains" do
    ping = stub_porkbun("/ping", { status: "SUCCESS", account: "acme", scopes: [ "dns" ], credentialsValid: true })
    stub_porkbun("/domain/listAll", { status: "SUCCESS", domains: %w[d.test b.test a.test c.test].map { |domain| { domain: domain } } })

    result = @adapter.connection_attributes(credentials: { "api_key" => " pk1_key ", "secret_key" => "sk1_secret\n" }, user: users(:user_1))

    assert_requested :post, "#{API}/ping", body: { apikey: "pk1_key", secretapikey: "sk1_secret" }.to_json,
                                           headers: { "Content-Type" => "application/json" }
    assert_requested ping
    assert_equal "Porkbun (acme): a.test, b.test, c.test and 1 more", result[:label]
    assert_equal "acme", result[:external_identity]
    assert_nil result[:external_subject_id]
    assert_equal({ "api_key" => "pk1_key", "secret_key" => "sk1_secret" }, result[:credential_payload])
    metadata = result[:credential_metadata]
    assert_equal %w[a.test b.test c.test d.test], metadata["domains"]
    assert_equal [ "dns" ], metadata["key_scopes"]
    assert_equal API, metadata["api_base"]
    assert_equal "static", metadata["credential_strategy"]
    assert_match "cannot buy domains", metadata["authority_summary"]
    assert_not_includes metadata.values.join(" "), "sk1_secret"
    assert_not_includes result[:credential_fingerprint], "pk1_key"
  end

  test "says plainly when a full key can spend money" do
    stub_porkbun("/ping", { status: "SUCCESS", account: "acme", scopes: [ "full" ] })
    stub_porkbun("/domain/listAll", { status: "SUCCESS", domains: [ { domain: "acme.test" } ] })

    summary = @adapter.connection_attributes(credentials: { "api_key" => "pk1_k", "secret_key" => "sk1_s" }, user: users(:user_1))
      .dig(:credential_metadata, "authority_summary")

    assert_match "Full access to acme.test", summary
    assert_match "buying, renewing and transferring", summary
    assert_match "only the dns scope", summary
  end

  test "unreported scopes are neither confirmed full access nor confirmed safe" do
    stub_porkbun("/ping", { status: "SUCCESS", account: "acme" })
    stub_porkbun("/domain/listAll", { status: "SUCCESS", domains: [ { domain: "acme.test" } ] })

    result = @adapter.connection_attributes(credentials: { "api_key" => "pk1_k", "secret_key" => "sk1_s" }, user: users(:user_1))
    summary = result.dig(:credential_metadata, "authority_summary")

    assert_equal [], result.dig(:credential_metadata, "key_scopes")
    assert_match "didn't say what this key may do", summary
    assert_match "may be able to buy domains", summary
    assert_no_match(/Full access/, summary)
    assert_no_match(/cannot buy/, summary)
  end

  test "names Porkbun's refusal and stops before listing domains" do
    stub_porkbun("/ping", { status: "ERROR", message: "Invalid API key. (002)" }, status: 400)
    list = stub_porkbun("/domain/listAll", { status: "SUCCESS", domains: [] })

    error = assert_raises(Services::PorkbunAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_key" => "pk1_k", "secret_key" => "sk1_wrong" }, user: users(:user_1))
    end

    assert_equal "Porkbun rejected this key pair (Invalid API key. (002))", error.message
    assert_not_requested list
  end

  test "a server error is a validation failure, not a rejection" do
    stub_request(:post, "#{API}/ping").to_return(status: 502, body: "<html>bad gateway</html>")

    error = assert_raises(Services::PorkbunAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_key" => "pk1_k", "secret_key" => "sk1_s" }, user: users(:user_1))
    end

    assert_equal "Porkbun validation failed (502)", error.message
  end

  test "requires both keys and notices them swapped, without calling Porkbun" do
    assert_equal "Porkbun secret API key is required",
                 assert_raises(Services::PorkbunAdapter::Error) { @adapter.connection_attributes(credentials: { "api_key" => "pk1_k" }, user: users(:user_1)) }.message
    assert_equal "Porkbun API key is required",
                 assert_raises(Services::PorkbunAdapter::Error) { @adapter.connection_attributes(credentials: {}, user: users(:user_1)) }.message
    swapped = assert_raises(Services::PorkbunAdapter::Error) do
      @adapter.connection_attributes(credentials: { "api_key" => "sk1_s", "secret_key" => "pk1_k" }, user: users(:user_1))
    end
    assert_match "swapped", swapped.message
    assert_not_requested :post, %r{api\.porkbun\.com}
  end

  private

  def stub_porkbun(path, body, status: 200)
    stub_request(:post, "#{API}#{path}")
      .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

end
